#!/bin/bash
# ==============================================================================
# 只评测 shopping_admin 单个站点（WebAgent-R1 / Eval）
#
# 当前模型：llama.cpp 部署的 Llama-3.1-8B-Instruct
#           http://219.222.20.79:31313/v1
#
# 它把四件原本分散的事串起来：
#   1. 任务筛选    scripts/filter_tasks_by_site.py    ← 挑出 shopping_admin 任务并重新编号
#   2. 模型配置    下面的"模型配置区"                ← evaluate.sh 里那一堆参数
#   3. 登录验证    scripts/check_login.py            ← auto_login 不校验登录是否真成功
#   4. 结果计分    scripts/score_subset.py            ← score.py 写死了 165，子集算不对
#
# 关于登录（重要）:
#   让 agent 带着登录态跑的是 run.py 自己 —— 它在每个任务前会重新调用
#   auto_login.py（写进临时目录）并改写该任务的 storage_state。
#   任务 JSON 里的 ./.auth/shopping_admin_state.json 只被用来取文件名推导站点组合，
#   内容从不读取。本脚本的 REFRESH_AUTH 是在**跑批量之前**先验证一次登录能不能成功，
#   因为 auto_login.py 的 --site_list 分支跳过了有效性校验，
#   而 35 个任务里有 14 个（program_html / url_match）没有登录态就会静默得 0 分。
#
# 用法:
#   bash evaluate_shopping_admin.sh              # 跑全部未完成的 shopping_admin 任务
#   LIMIT=3 bash evaluate_shopping_admin.sh      # 先跑 3 条试水
#   PARALLEL=2 bash evaluate_shopping_admin.sh   # 2 个进程并行
#   REFRESH_AUTH=0 bash evaluate_shopping_admin.sh   # 跳过登录刷新与验证
#   bash evaluate_shopping_admin.sh --score-only # 只重新计分，不跑任务
#
# 跑完再跑一次即可续跑（自动跳过已完成任务）。
#
# 前置条件:
#   - shopping_admin 容器已起（WebArena-Env-Setup/start_shopping_admin.sh）
#   - conda 环境已激活（README 里的 webagent-r1），且 PYTHON 与 PATH 里的 python 一致
#     （run.py 的登录子进程硬编码了 "python"，脚本会检查这一点）
#   - 评测机和容器在同一台机器（任务 JSON 里写死 localhost:8083）
# ==============================================================================

set -euo pipefail

# ============================ 站点配置区 =====================================
SITE="shopping_admin"
# 任务 JSON 里 start_url / reference_url 全部写死为 http://localhost:8083/...
# 所以评测必须跑在容器所在的那台机器上，这里保持 localhost。
# 若要从别的机器评测，把这里改成容器主机名/IP，脚本会用 --host 重写任务里的 URL。
PUBLIC_HOSTNAME="localhost"
SHOPPING_ADMIN_PORT=8083

# 用哪个 python 解释器（放一个同名的 wrapper 脚本或填绝对路径）
PYTHON="python"

# ============================ 模型配置区 =====================================
# 当前配置：llama.cpp 部署的 Meta-Llama-3.1-8B-Instruct
#
# llama.cpp 的 `llama-server` 自带 OpenAI 兼容接口，但**路径必须带 /v1**：
#     http://219.222.20.79:31313/v1/chat/completions
# 所以 PLANNER_IP 要写成 .../v1（代码里是 new OpenAI(base_url=...)，
# 它会自己往后拼 /chat/completions）。
#
# MODEL 用服务端 /v1/models 报出来的 id，别自己拼：
#     curl http://219.222.20.79:31313/v1/models
# llama.cpp 通常忽略这个字段，但填对更稳。
#
# provider 走 "openai"（openai 格式的兼容接口），不是 api_utils.py 里的 "api"。
#
# 备选：官方 / 第三方 OpenAI 兼容 API → PLANNER_IP="" 并填好下面两个变量
#
PROVIDER="openai"
MODEL="Llama-3.1-8B-Instruct-Q8_0.gguf"
MODE="chat"
PLANNER_IP="http://219.222.20.79:31313/v1"
# llama.cpp 不校验 API key，但 openai_utils.py 在 import 阶段就要读
# os.environ["OPENAI_API_KEY"]，缺了直接 KeyError，所以必须给非空占位。
# 走 planner_ip 时真正用的是 call_llm(api_key='EMPTY')，这里只是为了让进程能起来。
OPENAI_API_KEY="${OPENAI_API_KEY:-EMPTY}"
OPENAI_API_URL="${OPENAI_API_URL:-https://api.openai.com/v1}"

# prompt 模板：必须与 MODE / 模型相匹配
#   chat + thinking  : agent/prompts/jsons/p_webrl_chat_think.json   ← llama3.1 用这个
#   WebRL 纯文本风格 : agent/prompts/jsons/p_webrl.json  （配 MODE="completion"）
INSTRUCTION_PATH="agent/prompts/jsons/p_webrl_chat_think.json"
# llama3.1 的回合结束符就是 <|eot_id|>。
# 注意 llms/utils.py:37 在 chat 模式下会把 stop_token 硬编码成 None 传下去，
# 所以这里只在 MODE="completion" 时真正生效（chat 模式靠 EOS 停，不影响）。
STOP_TOKEN="<|eot_id|>"

# ============================ 运行配置区 =====================================
TASK_SRC_DIR="config_files/wa/test_webarena_lite"                    # 165 条全集
TASK_DIR="config_files/wa/test_webarena_lite_shopping_admin"         # 筛出来的目标集
RUN_DIR="config_files/_running_shopping_admin"                       # 本次待跑的子集
RESULT_DIR="eval_results/shopping_admin_llama3.1-8b"

LIMIT=0            # 只跑前 N 条（0=全部），试水用
PARALLEL=1         # 并发进程数；llama.cpp 单实例建议 1~2，别把它打爆
REFRESH_AUTH=1     # 1=先刷新 shopping_admin 登录 cookie
MAX_STEPS=30
TEMPERATURE=1.0
MAX_TOKENS=2048
MAX_OBS_LENGTH=0
VIEWPORT_WIDTH=1280
VIEWPORT_HEIGHT=720
ACTION_SET_TAG="webrl_id"
OBSERVATION_TYPE="webrl"

# =============================================================================

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { echo -e "\033[1;34m[eval]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

SCORE_ONLY=0
[[ "${1:-}" == "--score-only" ]] && SCORE_ONLY=1

# ---------- 环境变量 ----------
# env_config.py 对 6 个 URL 做非空断言；只跑 shopping_admin 时，
# 其余站点填一个必然连不上的本地地址：既不通过断言失败，也不会误连到别人的服务。
export DATASET="webarena"
export SHOPPING_ADMIN="http://${PUBLIC_HOSTNAME}:${SHOPPING_ADMIN_PORT}/admin"
export SHOPPING="http://127.0.0.1:1"
export REDDIT="http://127.0.0.1:1"
export GITLAB="http://127.0.0.1:1"
export WIKIPEDIA="http://127.0.0.1:1"
export MAP="http://127.0.0.1:1"
export HOMEPAGE="http://127.0.0.1:1"
# openai_utils.py 在 import 阶段就读 OPENAI_API_KEY，缺了直接 KeyError
export OPENAI_API_KEY OPENAI_API_URL

# ---------- 计分模式 ----------
if [[ $SCORE_ONLY -eq 1 ]]; then
  [[ -d "$TASK_DIR" ]] || die "任务目录不存在: $TASK_DIR，先跑一次完整流程"
  "$PYTHON" scripts/score_subset.py --result_dir "$RESULT_DIR" --task_dir "$TASK_DIR" --show-failed
  exit $?
fi

# ---------- 0. 前置检查 ----------
# run.py:405 里逐任务重新登录的子进程**硬编码**了 "python"（不是 sys.executable）。
# 所以 $PYTHON 和 PATH 里的 python 必须是同一个环境，否则登录子进程会用错解释器，
# 表现为任务报错跳过（error.txt 里能看到 assert 失败）。
if [[ "$PYTHON" != "python" ]]; then
  p_target="$("$PYTHON" -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
  p_path="$(command -v python 2>/dev/null || true)"
  if [[ -z "$p_path" ]]; then
    warn "PATH 里没有 python，但 run.py 的登录子进程硬编码了 \"python\"，登录会失败"
    warn "  建议先 conda activate，再把 PYTHON 设回 python"
  elif [[ -n "$p_target" && "$p_target" != "$p_path" ]]; then
    die "PYTHON 与 PATH 里的 python 不是同一个环境：
    PYTHON = $p_target
    python = $p_path
  run.py:405 的登录子进程用的是裸 \"python\"，两者不一致会让逐任务登录失败。
  解决：先 conda activate <环境>，然后把脚本里的 PYTHON 设回 "python""
  fi
fi

say "检查站点可达性: $SHOPPING_ADMIN"
code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$SHOPPING_ADMIN" 2>/dev/null || true)"
[[ -n "$code" ]] || code="000"
if [[ ! "$code" =~ ^(200|301|302)$ ]]; then
  die "shopping_admin 不可达（HTTP $code）。
  先启动容器: sudo bash ../WebArena-Env-Setup/start_shopping_admin.sh"
fi
say "站点正常（HTTP $code）"

if [[ -n "$PLANNER_IP" && "${SKIP_MODEL_CHECK:-0}" != "1" ]]; then
  say "检查模型端点: ${PLANNER_IP%/}/models"
  if ! curl -s -m 15 "${PLANNER_IP%/}/models" >/dev/null 2>&1; then
    die "模型端点不可达: ${PLANNER_IP%/}/models
  llama.cpp 的 OpenAI 兼容接口路径必须带 /v1，确认 PLANNER_IP 形如 http://host:port/v1
  确实想跳过这个检查: SKIP_MODEL_CHECK=1 bash $0"
  fi
  say "模型端点正常"
fi

# ---------- 1. 生成任务集（只做一次） ----------
if [[ ! -d "$TASK_DIR" ]]; then
  say "任务目录不存在，正在生成…"
  "$PYTHON" scripts/filter_tasks_by_site.py --src "$TASK_SRC_DIR" --dst "$TASK_DIR" \
    --site "$SITE" --host "$PUBLIC_HOSTNAME"
else
  n=$(ls -1 "$TASK_DIR"/*.json 2>/dev/null | wc -l)
  say "复用已有任务目录 $TASK_DIR（$n 条）"
fi

# ---------- 2. 挑出未完成的任务（断点续跑） ----------
# run.py 自带的续跑判断用文件名序号查 actions/，对重新编号过的目录会失效，
# 所以这里自己按内部 task_id 过滤，生成一个新的连续编号目录。
say "生成本次待跑子集（自动跳过已完成）…"
"$PYTHON" scripts/filter_tasks_by_site.py \
  --src "$TASK_DIR" --dst "$RUN_DIR" --site "$SITE" \
  --exclude-done "$RESULT_DIR" --limit "$LIMIT" --overwrite \
  --host "$PUBLIC_HOSTNAME"

total=$(ls -1 "$RUN_DIR"/*.json 2>/dev/null | wc -l || echo 0)
if [[ "$total" -eq 0 ]]; then
  say "没有待跑的任务了，直接计分："
  "$PYTHON" scripts/score_subset.py --result_dir "$RESULT_DIR" --task_dir "$TASK_DIR" --show-failed
  exit $?
fi
say "本次待跑 $total 条任务"

# ---------- 3. 刷新登录 cookie ----------
# 说明：真正让 agent 带着登录态跑的是 run.py 自己 —— 它在每个任务前会调用
#   subprocess.run(["python", "browser_env/auto_login.py", "--auth_folder",
#                   <临时目录>, "--site_list", "shopping_admin"])
# 重新登录一次，并把该任务的 storage_state 指向临时目录里的新 cookie。
# 任务 JSON 里那个 ./.auth/shopping_admin_state.json 其实**只被用来取文件名**
# 推导站点组合，内容从不读取。所以这一步的价值是提前验证"登录能不能成功"，
# 而不是提供登录态本身。
if [[ "$REFRESH_AUTH" == "1" ]]; then
  say "刷新 $SITE 登录 cookie…"
  mkdir -p .auth
  if "$PYTHON" browser_env/auto_login.py --site_list "$SITE" --auth_folder ./.auth; then
    say "cookie 已写入 ./.auth/${SITE}_state.json"

    # auto_login.py 走 --site_list 分支时**跳过** is_expired 校验，
    # 所以脚本跑完不代表真登录上了。这里实际打开一次后台页面确认。
    say "验证登录是否真的有效…"
    if "$PYTHON" scripts/check_login.py --state-file "./.auth/${SITE}_state.json"; then
      say "登录有效 ✅"
    else
      die "登录无效！这不只是个警告 —— 35 个任务里有 14 个（program_html / url_match）
  需要已登录的浏览器上下文，评测器会重新 page.goto() 后台页面取 DOM，
  没登录会被 Magento 重定向到登录页，locator 查不到元素 → 这些任务静默得 0 分。
  确认无误后想跳过这个检查: REFRESH_AUTH=0 bash $0"
    fi
  else
    warn "cookie 刷新失败。run.py 会按任务自己重新登录，但建议先解决上面的报错"
  fi
fi

mkdir -p "$RESULT_DIR" logs

# ---------- 4. 跑评测 ----------
run_chunk() {
  local start="$1" end="$2"
  "$PYTHON" run.py \
    --instruction_path "$INSTRUCTION_PATH" \
    --test_start_idx "$start" \
    --test_end_idx "$end" \
    --test_config_base_dir "$RUN_DIR" \
    --result_dir "$RESULT_DIR" \
    --provider "$PROVIDER" \
    --model "$MODEL" \
    --mode "$MODE" \
    --planner_ip "$PLANNER_IP" \
    --stop_token "$STOP_TOKEN" \
    --temperature "$TEMPERATURE" \
    --max_tokens "$MAX_TOKENS" \
    --max_obs_length "$MAX_OBS_LENGTH" \
    --max_steps "$MAX_STEPS" \
    --viewport_width "$VIEWPORT_WIDTH" \
    --viewport_height "$VIEWPORT_HEIGHT" \
    --parsing_failure_th 5 \
    --repeating_action_failure_th 5 \
    --action_set_tag "$ACTION_SET_TAG" \
    --observation_type "$OBSERVATION_TYPE"
}

if [[ "$PLANNER_IP" == "" ]]; then
  say "模型: provider=$PROVIDER model=$MODEL mode=$MODE  → 走 OPENAI_API_URL=$OPENAI_API_URL"
else
  say "模型: provider=$PROVIDER model=$MODEL mode=$MODE  → $PLANNER_IP"
fi
say "任务: $TASK_DIR / 本次 $total 条 / 并发 $PARALLEL"

if [[ "$PARALLEL" -le 1 ]]; then
  run_chunk 0 "$total"
else
  chunk=$(( (total + PARALLEL - 1) / PARALLEL ))
  pids=()
  for ((i = 0; i < PARALLEL; i++)); do
    s=$((i * chunk))
    if [[ $s -ge $total ]]; then break; fi
    e=$((s + chunk))
    if [[ $e -gt $total ]]; then e=$total; fi
    say "  进程 $i: 任务 [$s, $e)"
    run_chunk "$s" "$e" >"logs/chunk_${i}.log" 2>&1 &
    pids+=($!)
  done
  status=0
  for pid in "${pids[@]}"; do
    wait "$pid" || status=1
  done
  [[ $status -eq 0 ]] || warn "有进程非正常退出，看 logs/chunk_*.log；再跑一次本脚本会自动续跑"
fi

# ---------- 5. 计分 ----------
echo
"$PYTHON" scripts/score_subset.py --result_dir "$RESULT_DIR" --task_dir "$TASK_DIR" --show-failed

cat <<EOF

  结果目录 : $RESULT_DIR
  任务集   : $TASK_DIR
  模型     : $MODEL  ($PLANNER_IP)
  单条重跑 : $PYTHON run.py --test_config_base_dir $TASK_DIR \\
               --test_start_idx <序号> --test_end_idx <序号+1> ...（其余参数见本脚本）
  纯计分   : bash $(basename "$0") --score-only
EOF
