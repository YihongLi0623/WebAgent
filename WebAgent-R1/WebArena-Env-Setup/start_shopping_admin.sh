#!/bin/bash
# ==============================================================================
# 只启动 WebArena 的 shopping_admin (Magento Admin) 站点
# 由 01/02/03/04/05 号脚本精简而来，不涉及 shopping / reddit / gitlab / wiki / map
#
# 用法:
#   bash start_shopping_admin.sh                    # 正常启动（已存在则复用）
#   bash start_shopping_admin.sh /path/to/tar       # 临时指定 tar 包路径
#   TAR_FILE=/path/to/tar bash start_shopping_admin.sh
#   bash start_shopping_admin.sh --reset            # 先删掉旧容器再重建（数据会重置）
# ==============================================================================

set -euo pipefail

# -------------------------------- 配置区 -------------------------------------
CONTAINER_NAME="shopping_admin"
IMAGE_NAME="shopping_admin_final_0719"

# tar 包绝对路径：改成你自己的位置（Windows Git Bash 用 /d/xxx 这种写法）
TAR_FILE="${TAR_FILE:-/d/images/shopping_admin_final_0719.tar}"

PUBLIC_HOSTNAME="10.154.22.10"      # 与 00_vars.sh 保持一致
SHOPPING_ADMIN_PORT=8083

# MySQL 凭据（镜像内置，与 05_docker_patch_containers.sh 一致）
MYSQL_USER="magentouser"
MYSQL_PASS="MyPassword"
MYSQL_DB="magentodb"
MAGENTO_BIN="/var/www/magento2/bin/magento"
# -----------------------------------------------------------------------------

# 命令行第一个参数：--reset 或 tar 路径
RESET=0
if [[ $# -ge 1 ]]; then
  case "$1" in
    --reset) RESET=1 ;;
    --help|-h)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) TAR_FILE="$1" ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

say()  { echo -e "\033[1;34m[shopping_admin]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

ADMIN_URL="http://${PUBLIC_HOSTNAME}:${SHOPPING_ADMIN_PORT}/admin"

# 1) 检查 docker
docker info >/dev/null 2>&1 || die "Docker 未运行或不可用，请先启动 Docker Desktop"

# 2) 加载镜像（已存在则跳过；本地无 tar 但镜像已有也能跑）
image_exists() {
  docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1
}

if image_exists; then
  say "镜像 ${IMAGE_NAME} 已存在，跳过 docker load"
else
  [[ -f "$TAR_FILE" ]] || die "找不到 tar 包: ${TAR_FILE}
  请修改脚本顶部的 TAR_FILE 变量，或用参数传入: bash $0 /your/path/shopping_admin_final_0719.tar"
  say "加载镜像 ${IMAGE_NAME} <- ${TAR_FILE} (约几分钟，只有首次需要)"
  docker load --input "$TAR_FILE"
  image_exists || die "docker load 后仍未找到镜像 ${IMAGE_NAME}"
fi

# 3) 清理旧容器（--reset 时强制重建，否则复用已有容器）
if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  if [[ $RESET -eq 1 ]]; then
    say "--reset: 删除旧容器 ${CONTAINER_NAME}"
    docker rm -f "$CONTAINER_NAME" >/dev/null
  else
    say "容器 ${CONTAINER_NAME} 已存在，直接复用（如需重建请加 --reset）"
  fi
fi

# 4) 创建并启动容器
if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  say "创建容器 ${CONTAINER_NAME} (0.0.0.0:${SHOPPING_ADMIN_PORT} -> 80)"
  docker create --name "$CONTAINER_NAME" -p "${SHOPPING_ADMIN_PORT}:80" "${IMAGE_NAME}"
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]]; then
  say "启动容器..."
  docker start "$CONTAINER_NAME" >/dev/null
else
  say "容器已在运行"
fi

# 5) 等待 MySQL 就绪
say "等待 MySQL 就绪..."
MYSQL_UP=0
for i in $(seq 1 60); do
  if docker exec "$CONTAINER_NAME" bash -c \
      "mysqladmin -u ${MYSQL_USER} -p${MYSQL_PASS} --silent ping 2>/dev/null | grep -q alive" 2>/dev/null; then
    MYSQL_UP=1; break
  fi
  if docker exec "$CONTAINER_NAME" bash -c \
      "mysql -u ${MYSQL_USER} -p${MYSQL_PASS} -e 'SELECT 1' ${MYSQL_DB}" >/dev/null 2>&1; then
    MYSQL_UP=1; break
  fi
  sleep 3
done
[[ $MYSQL_UP -eq 1 ]] || warn "MySQL 等待超时，后续 magento 配置命令可能失败"

# 6) 应用 patch（去掉强制改密码、设置 base-url、刷缓存）—— 幂等，可重复执行
say "配置 Magento (base-url / 密码策略)..."
docker exec "$CONTAINER_NAME" php "${MAGENTO_BIN}" config:set admin/security/password_is_forced 0  || warn "password_is_forced 设置失败"
docker exec "$CONTAINER_NAME" php "${MAGENTO_BIN}" config:set admin/security/password_lifetime 0   || warn "password_lifetime 设置失败"

docker exec "$CONTAINER_NAME" "${MAGENTO_BIN}" \
  setup:store-config:set --base-url="http://${PUBLIC_HOSTNAME}:${SHOPPING_ADMIN_PORT}" || warn "base-url 设置失败"

docker exec "$CONTAINER_NAME" mysql -u "${MYSQL_USER}" -p"${MYSQL_PASS}" "${MYSQL_DB}" -e \
  "UPDATE core_config_data SET value='http://${PUBLIC_HOSTNAME}:${SHOPPING_ADMIN_PORT}/' WHERE path = 'web/secure/base_url';" || warn "secure base_url 更新失败"

docker exec "$CONTAINER_NAME" "${MAGENTO_BIN}" cache:flush || warn "cache:flush 失败"

# 7) 等待 HTTP 可访问
say "等待站点可访问..."
HTTP_OK=0
for i in $(seq 1 40); do
  code=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "${ADMIN_URL}" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^(200|302|301)$ ]]; then HTTP_OK=1; break; fi
  sleep 3
done

echo
if [[ $HTTP_OK -eq 1 ]]; then
  say "✅ 启动完成"
else
  warn "站点暂未返回 200，可能还在编译/初始化，稍等几十秒再试"
fi
cat <<EOF

  Admin 后台 : ${ADMIN_URL}
  账号/密码  : admin / admin1234
  容器名     : ${CONTAINER_NAME}
  镜像       : ${IMAGE_NAME}

  常用命令:
    docker logs -f ${CONTAINER_NAME}
    docker exec -it ${CONTAINER_NAME} bash
    docker stop ${CONTAINER_NAME}        # 停止
    docker start ${CONTAINER_NAME}       # 再次启动
    bash $0 --reset            # 销毁重建（恢复初始数据）
EOF
