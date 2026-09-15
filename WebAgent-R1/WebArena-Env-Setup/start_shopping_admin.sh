#!/bin/bash
# ==============================================================================
# 只启动 WebArena 的 shopping_admin (Magento Admin) 站点
# 由 01/02/03/04/05 号脚本精简而来，不涉及 shopping / reddit / gitlab / wiki / map
#
# 用法（Linux 环境，路径均为 Linux 绝对路径）:
#   bash start_shopping_admin.sh                      # 正常启动（已存在则复用）
#   bash start_shopping_admin.sh /data/xxx.tar        # 临时指定 tar 包路径
#   TAR_FILE=/data/xxx.tar bash start_shopping_admin.sh
#   bash start_shopping_admin.sh --reset              # 删掉旧容器再重建（数据重置）
#   bash start_shopping_admin.sh --help
# ==============================================================================

set -euo pipefail

# -------------------------------- 配置区 -------------------------------------
CONTAINER_NAME="shopping_admin"

# 镜像名。tar 包里的真实 tag 与这里不一致时，脚本会自动从 tar 中解析并纠正
IMAGE_NAME="${IMAGE_NAME:-am1n3e/webarena-verified-shopping_admin}"

# tar 包绝对路径（Linux 路径格式）。注意默认值语法是 ${VAR:-default}，那个 '-' 不能少
TAR_FILE="${TAR_FILE:-/mnt/mess/liyihong/webarena_tar/webarena-shopping-admin.tar}"

# 找不到 TAR_FILE 时的兜底搜索目录（Linux 绝对路径，多个用空格分隔）
SEARCH_DIRS="/mnt/mess/liyihong/webarena_tar /root /home/webarena /data /opt/webarena ."

PUBLIC_HOSTNAME="10.154.22.10"      # 与 00_vars.sh 保持一致
SHOPPING_ADMIN_PORT=8083

# MySQL 凭据（镜像内置，与 05_docker_patch_containers.sh 一致）
MYSQL_USER="magentouser"
MYSQL_PASS="MyPassword"
MYSQL_DB="magentodb"
MAGENTO_BIN="/var/www/magento2/bin/magento"
# -----------------------------------------------------------------------------

RESET=0
if [[ $# -ge 1 ]]; then
  case "$1" in
    --reset) RESET=1 ;;
    --help|-h)
      sed -n '2,13p' "$0"; exit 0 ;;
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
if ! docker info >/dev/null 2>&1; then
  die "Docker 不可用。请确认 docker 服务已启动（systemctl status docker），
  若当前用户不在 docker 组，请用 sudo bash $0 重试"
fi

image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

# 从 tar 的 manifest.json 里解析真实镜像 tag（tar / tar.gz 都支持）
# 注意：不要用 grep -o '"[^"]*:[^"]*"' 直接抓，它会先匹配到 "RepoTags":[ 这种垃圾
detect_image_name_from_tar() {
  local tar="$1" manifest arr tag
  if [[ ! -f "$tar" ]]; then
    echo ""
    return 0
  fi
  # GNU tar 会自动识别 gzip 压缩
  manifest="$(tar -xOf "$tar" manifest.json 2>/dev/null || tar -xOzf "$tar" manifest.json 2>/dev/null || true)"
  if [[ -z "$manifest" ]]; then
    echo ""
    return 0
  fi
  # 按 manifest 条目切行 -> 取第一个含 RepoTags 的条目 -> 取出数组内容
  arr="$(printf '%s' "$manifest" | tr -d '\n' \
        | sed 's/},{/}\n{/g' \
        | grep -m1 '"RepoTags"' \
        | sed -n 's/.*"RepoTags"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' || true)"
  if [[ -z "$arr" ]]; then
    echo ""
    return 0
  fi
  # 多 tag 时取第一个
  tag="$(printf '%s' "$arr" | tr ',' '\n' | head -n 1 | tr -d ' "' || true)"
  echo "$tag"
}

# 在候选目录里找 tar 包
find_tar() {
  local want base dir
  base="$(basename "$TAR_FILE")"
  for dir in $SEARCH_DIRS; do
    [[ -d "$dir" ]] || continue
    for want in "$dir/$base" "$dir/shopping_admin_final_0719.tar" "$dir/shopping-admin.tar"; do
      if [[ -f "$want" ]]; then echo "$want"; return 0; fi
    done
  done
  echo ""
}

# 2) 加载镜像（已存在则跳过；本地无 tar 但镜像已有也能跑）
if image_exists "$IMAGE_NAME"; then
  say "镜像 ${IMAGE_NAME} 已存在，跳过 docker load"
else
  # tar 不存在时先尝试兜底搜索
  if [[ ! -f "$TAR_FILE" ]]; then
    found="$(find_tar)"
    if [[ -n "$found" ]]; then
      say "未找到 ${TAR_FILE}，改用 ${found}"
      TAR_FILE="$found"
    fi
  fi

  [[ -f "$TAR_FILE" ]] || die "找不到 tar 包: ${TAR_FILE}
  已搜索过: ${SEARCH_DIRS}
  请修改脚本顶部 TAR_FILE 变量，或传参: sudo bash $0 /your/path/xxx.tar"

  # 若 tar 里的真实 tag 与 IMAGE_NAME 不同，以 tar 内的为准
  tar_tag="$(detect_image_name_from_tar "$TAR_FILE")"
  if [[ -n "$tar_tag" && "$tar_tag" != "$IMAGE_NAME" && "${tar_tag%%:*}" != "$IMAGE_NAME" ]]; then
    if [[ "${tar_tag%%:*}" != "${IMAGE_NAME%%:*}" ]]; then
      warn "tar 内镜像名为 ${tar_tag}，与配置的 ${IMAGE_NAME} 不一致，按 tar 内的为准"
    fi
    IMAGE_NAME="$tar_tag"
  fi

  say "加载镜像 ${IMAGE_NAME} <- ${TAR_FILE}（首次较慢，可用 ctrl-c 中断）"
  docker load --input "$TAR_FILE"
  image_exists "$IMAGE_NAME" || die "docker load 后仍未找到镜像 ${IMAGE_NAME}"
fi

# 3) 旧容器处理
if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  if [[ $RESET -eq 1 ]]; then
    say "--reset: 删除旧容器 ${CONTAINER_NAME}"
    docker rm -f "$CONTAINER_NAME" >/dev/null
  else
    cur_image="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    if [[ -n "$cur_image" && "$cur_image" != "$IMAGE_NAME" ]]; then
      warn "已有容器用的是镜像 ${cur_image}，与当前 ${IMAGE_NAME} 不同"
      warn "如需按新镜像重建，请执行: sudo bash $0 --reset"
    fi
    say "容器 ${CONTAINER_NAME} 已存在，直接复用（重建请加 --reset）"
  fi
fi

# 4) 创建并启动容器
if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  say "创建容器 ${CONTAINER_NAME} (0.0.0.0:${SHOPPING_ADMIN_PORT} -> 80)"
  docker create --name "$CONTAINER_NAME" \
    -p "${SHOPPING_ADMIN_PORT}:80" \
    "${IMAGE_NAME}" \
    || die "容器创建失败，常见原因：端口 ${SHOPPING_ADMIN_PORT} 已被占用（ss -lntp | grep ${SHOPPING_ADMIN_PORT}）"
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
for _ in $(seq 1 60); do
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
if [[ $MYSQL_UP -ne 1 ]]; then
  warn "MySQL 等待超时（180s），后续 magento 配置命令可能失败"
  warn "排查: docker logs --tail 50 ${CONTAINER_NAME}"
fi

# 6) 应用 patch（幂等，可重复执行）
say "配置 Magento (base-url / 密码策略)..."
docker exec "$CONTAINER_NAME" php "${MAGENTO_BIN}" config:set admin/security/password_is_forced 0 || warn "password_is_forced 设置失败"
docker exec "$CONTAINER_NAME" php "${MAGENTO_BIN}" config:set admin/security/password_lifetime 0  || warn "password_lifetime 设置失败"

docker exec "$CONTAINER_NAME" "${MAGENTO_BIN}" \
  setup:store-config:set --base-url="http://${PUBLIC_HOSTNAME}:${SHOPPING_ADMIN_PORT}" || warn "base-url 设置失败"

docker exec "$CONTAINER_NAME" mysql -u "${MYSQL_USER}" -p"${MYSQL_PASS}" "${MYSQL_DB}" -e \
  "UPDATE core_config_data SET value='http://${PUBLIC_HOSTNAME}:${SHOPPING_ADMIN_PORT}/' WHERE path = 'web/secure/base_url';" || warn "secure base_url 更新失败"

docker exec "$CONTAINER_NAME" "${MAGENTO_BIN}" cache:flush || warn "cache:flush 失败"

# 7) 等待 HTTP 可访问
say "等待站点可访问..."
HTTP_OK=0
for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$ADMIN_URL" 2>/dev/null || echo 000)"
  if [[ "$code" =~ ^(200|301|302)$ ]]; then HTTP_OK=1; break; fi
  sleep 3
done

echo
if [[ $HTTP_OK -eq 1 ]]; then
  say "启动完成 ✅"
else
  warn "站点暂未返回 200/302（可能仍在初始化），稍等几十秒重试"
  warn "排查: docker logs -f ${CONTAINER_NAME}"
fi
cat <<EOF

  Admin 后台 : ${ADMIN_URL}
  账号/密码  : admin / admin1234
  容器名     : ${CONTAINER_NAME}
  镜像       : ${IMAGE_NAME}

  常用命令:
    docker logs -f ${CONTAINER_NAME}
    docker exec -it ${CONTAINER_NAME} bash
    docker stop  ${CONTAINER_NAME}     # 停止
    docker start ${CONTAINER_NAME}     # 再次启动
    bash $0 --reset               # 销毁重建（恢复初始数据）
EOF
