#!/bin/bash
# ==============================================================================
# 只评测 shopping_admin 单个站点（WebAgent-R1 / Eval）
#
# 当前模型：vLLM 部署的 Qwen3.8-27B-QUASAR-NVFP4（多模态 + 思考模型）
#           https://inference.cluster.aimodelnetwork.cn/QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4/v1
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
# 关于「每次跑全部 35 条」:
#   不做断点续跑，每次运行都完整跑一遍。这不是只删掉本脚本的过滤就行 ——
#   run.py:671 自己会调 get_unfinished() 跳过它认为已完成的任务，判据是
#   「文件名序号」查 actions/{序号}.json + render_*.html 反推。我们的目录文件名是
#   0..34 而内部 task_id 是 0,2,8,13,17... 两者不对齐，这套判据会看错记录、
#   随机跳过十来个任务。所以脚本在开跑前把结果目录整体改名备份（FRESH_RUN=1），
#   让 run.py 看到空目录 → 35 条全跑。
#
# 用法:
#   bash evaluate_shopping_admin.sh              # 完整跑 35 条（每次都是全量）
#   LIMIT=3 bash evaluate_shopping_admin.sh      # 只跑前 3 条试水
#   d   # 2 个进程并行
#   FRESH_RUN=0 bash evaluate_shopping_admin.sh  # 保留上次结果（会被 run.py 跳过部分任务）
#   REFRESH_AUTH=0 bash evaluate_shopping_admin.sh   # 跳过登录刷新与验证
#   bash evaluate_shopping_admin.sh --score-only # 只重新计分，不跑任务
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
# 当前配置：vLLM 部署的 Qwen3.8-27B-QUASAR-NVFP4（多模态 + 思考模型）
#
# 端点实测（2026-09-16）：
#   GET  <PLANNER_IP>/models            -> 200
#        {"id":"QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4","owned_by":"vllm","max_model_len":200000}
#   POST <PLANNER_IP>/chat/completions  -> 200，且**不校验 Authorization**（带假 key 也是 200）
#
# 三个必须注意的点：
#   1) base_url 要写到 /v1 为止，而且**模型名本身就是 URL 路径的一部分**：
#        https://.../QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4/v1
#      实测 /QUASAR-QAT/.../models（少 /v1）和根路径 /v1/models 都返回 404。
#      代码里是 OpenAI(base_url=PLANNER_IP)，它会自己往后拼 /chat/completions，
#      所以 PLANNER_IP 末尾只到 /v1，不要再带 /chat/completions。
#   2) MODEL 要写**带命名空间的完整 id**：QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4。
#      写短名 "Qwen3.8-27B-QUASAR-NVFP4" 会被网关拒：
#        404 The model `Qwen3.8-27B-QUASAR-NVFP4` does not exist.
#   3) 这是**思考模型**：服务端把思维链拆到独立的 reasoning 字段，content 里只剩答案
#      （形如 "\n\n<answer>do(...)</answer>"）。Eval 侧只读
#      response.choices[0].message.content（openai_utils.py:286），
#      所以被拆出去的 reasoning 不会干扰动作解析 —— 正好合适。
#      但思维链同样消耗 completion token，所以下面 MAX_TOKENS 提到了 4096；
#      否则无障碍树稍大就会在 thinking 阶段被截断、拿不到 <answer> → 解析失败累积。
#
# 它同时是**多模态模型**（实测能正确读 image_url）。不过本评测走 WebAgent-R1 的
# 文本协议（observation_type=webrl，读无障碍树），WebRLChatPromptConstructor
# 只拼文本 obs、不送图，所以这里不需要也无法启用图像观测。
#
# provider 走 "openai"（OpenAI 兼容接口），不是 api_utils.py 里的 "api"。
#
# 备选：官方 / 第三方 OpenAI 兼容 API → PLANNER_IP="" 并填好下面两个变量
#
PROVIDER="openai"
MODEL="QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4"
MODE="chat"
PLANNER_IP="https://inference.cluster.aimodelnetwork.cn/QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4/v1"
# 这个端点不校验鉴权，但 openai_utils.py 在 import 阶段就要读
# os.environ["OPENAI_API_KEY"]，缺了直接 KeyError，所以必须给非空占位。
# 走 planner_ip 时真正用的是 call_llm(api_key='EMPTY')，这里只是为了让进程能起来。
OPENAI_API_KEY="${OPENAI_API_KEY:-EMPTY}"
OPENAI_API_URL="${OPENAI_API_URL:-https://api.openai.com/v1}"

# prompt 模板：必须与 MODE / 模型相匹配。
# 这个模板的 system prompt 明确要求按
#   <think> ... </think> 换行 <answer> ... </answer>
# 的格式作答；服务端会把 <think> 段拆到 reasoning 字段、content 里只留 <answer>，
# 而 WebRLChatPromptConstructor.extract_action() 正是"有 <answer> 就取标签内"，
# 两边能对上。
#   chat + thinking  : agent/prompts/jsons/p_webrl_chat_think.json   ← 当前用这个
#   WebRL 纯文本风格 : agent/prompts/jsons/p_webrl.json  （配 MODE="completion"）
INSTRUCTION_PATH="agent/prompts/jsons/p_webrl_chat_think.json"
# Qwen 系列的回合结束符是 <|im_end|>。
# 注意 llms/utils.py:37 在 chat 模式下会把 stop_token 硬编码成 None 传下去，
# 所以这里只在 MODE="completion" 时真正生效（chat 模式靠 EOS 停，不影响）。
STOP_TOKEN="<|im_end|>"

# ============================ 运行配置区 =====================================
TASK_SRC_DIR="config_files/wa/test_webarena_lite"                    # 165 条全集
TASK_DIR="config_files/wa/test_webarena_lite_shopping_admin"         # 筛出来的目标集（0..34.json 连续编号，可直接给 run.py）
RESULT_DIR="eval_results/shopping_admin_qwen3.8-27b-quasar"

LIMIT=0            # 只跑前 N 条（0=全部 35 条），试水用
PARALLEL=4         # 并发 run.py 进程数。1=串行；4=把 35 条切成 4 段同时跑。
                   # 命令行覆盖：PARALLEL=4 bash evaluate_shopping_admin.sh
                   # 参考：单实例 llama.cpp + 每进程一个 Chromium，4 左右比较稳；
                   #       调太大主要卡在模型推理排队和内存上。
REFRESH_AUTH=1     # 1=先刷新并验证 shopping_admin 登录
MAX_STEPS=30
TEMPERATURE=1.0    # 思考模型想更稳可以试 0.6（vLLM 对 Qwen3 思考模式的常用值）
MAX_TOKENS=4096    # 思考 token 也算在里面，2048 容易被 thinking 吃光、答案被截断
MAX_OBS_LENGTH=0
VIEWPORT_WIDTH=1280
VIEWPORT_HEIGHT=720
ACTION_SET_TAG="webrl_id"
OBSERVATION_TYPE="webrl"

# 每次跑都完整跑一遍全部任务，不复用上次结果。
# 为什么必须要这个开关：run.py:671 自己会调 get_unfinished() 过滤任务，而它用
# **文件名序号** 去查 actions/{序号}.json、用 render_*.html 反推已跑过的 id。
# 这套判断对重新编号过的目录本来就不成立（文件名是 0..34，内部 task_id 是 0,2,8,13...），
# 结果就是第二次跑会莫名其妙跳过十来个任务、而且跳过的判据还看错了记录。
# 所以这里在开跑前把上次的结果目录整体挪走，让 run.py 看到一个空目录 → 35 条全跑。
FRESH_RUN=1        # 1=把旧结果改名备份后重跑；0=保留旧结果（run.py 可能跳过部分任务）

# =============================================================================

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { echo -e "\033[1;34m[eval]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

# set -e 下任何一步失败都会静默退出 —— 看不到是第几行、什么命令失败，也来不及计分。
# 这个 trap 把失败位置和命令打出来；想知道完整执行轨迹可以 bash -x 运行本脚本。
trap 'rc=$?; echo -e "\033[1;31m[error]\033[0m 第 $LINENO 行失败（退出码 $rc）: $BASH_COMMAND" >&2' ERR

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
  # 注意 `|| true` 不能写成 `|| echo 0`：ls 失败时 wc 已经输出了 0，再 echo 一个 0
  # 会变成 "0\n0"，后面 `[[ -gt ]]` 直接语法报错。
  n=$(ls -1 "$TASK_DIR"/*.json 2>/dev/null | wc -l || true)
  say "复用已有任务目录 $TASK_DIR（$n 条）"
fi

# ---------- 2. 清空上次结果，确保 35 条全跑 ----------
# 见上面 FRESH_RUN 的说明：run.py 自己会跳过它认为已完成的任务，
# 而它的判据（文件名序号 + render_*.html）在我们的重新编号目录上不成立，
# 所以每次跑之前把结果目录挪走，让它看到空目录 → 全部任务都会跑。
if [[ "$FRESH_RUN" == "1" && -d "$RESULT_DIR" ]]; then
  backup="${RESULT_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
  say "备份上次结果: $RESULT_DIR -> $backup"
  mv "$RESULT_DIR" "$backup"
  warn "旧结果已备份到 $backup（不需要就自己删）"
fi

total=$(ls -1 "$TASK_DIR"/*.json 2>/dev/null | wc -l || true)
[[ "$total" -gt 0 ]] || die "任务目录里没有任务: $TASK_DIR"
if [[ "$LIMIT" -gt 0 && "$LIMIT" -lt "$total" ]]; then
  warn "LIMIT=$LIMIT，本次只跑前 $LIMIT 条（不是完整 35 条）"
  total="$LIMIT"
fi
say "本次将跑 $total 条任务（每次都是完整跑，不跳过任何一条）"

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
    --test_config_base_dir "$TASK_DIR" \
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
if [[ "$PARALLEL" -gt "$total" ]]; then
  warn "PARALLEL=$PARALLEL 大于任务数 $total，实际只会起 $total 个进程（每个跑 1 条）"
fi
say "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
START_TS=$SECONDS

# 并行方式：把 [0, total) 切成 PARALLEL 段，每段一个 run.py 进程跑
#   python run.py --test_start_idx <段起> --test_end_idx <段止>
# 写的是同一个 result_dir，但每个任务的结果文件是 actions/<内部task_id>.json，
# 各段任务不重叠，所以互不干扰。
#
# 这里刻意用 `|| RUN_OK=0` 接住失败，而不是让 set -e 直接退出：
# run.py 只要有一个任务抛出未捕获异常（模型报错、登录断言失败、页面超时…）
# 就会以非零码结束。放任 set -e 生效的话，脚本会在这一行**静默退出** ——
# 既不打印原因，也跳过后面的计分（就是上一轮"跑完没评分"的那个现象）。
RUN_OK=1
if [[ "$PARALLEL" -le 1 ]]; then
  run_chunk 0 "$total" 2>&1 | tee "logs/run_$(date +%Y%m%d-%H%M%S).log" || RUN_OK=0
else
  # 注意 1：多个 run.py 进程共用一个 result_dir。它们在启动时各自会调一次
  # get_unfinished()（在 import + prepare 之后），此刻目录还是空的，所以都能拿到
  # 完整的任务列表。只要不在跑的过程中人为往 result_dir 塞文件就不会误跳。
  # 注意 2：debug_info/ 是进程共用的固定路径（相对 cwd），并行时各进程会互相覆盖，
  # 只影响调试文件，不影响评分。
  chunk=$(( (total + PARALLEL - 1) / PARALLEL ))
  pids=()
  for ((i = 0; i < PARALLEL; i++)); do
    s=$((i * chunk))
    if [[ $s -ge $total ]]; then break; fi
    e=$((s + chunk))
    if [[ $e -gt $total ]]; then e=$total; fi
    say "  进程 $i: 任务 [$s, $e)  共 $((e - s)) 条  → logs/chunk_${i}.log"
    run_chunk "$s" "$e" >"logs/chunk_${i}.log" 2>&1 &
    pids+=($!)
  done
  RUN_OK=0
  for pid in "${pids[@]}"; do
    wait "$pid" || RUN_OK=1
  done
fi

say "结束时间: $(date '+%Y-%m-%d %H:%M:%S')   总耗时 $((SECONDS - START_TS)) 秒"
say "（想提速就把 PARALLEL 调大：PARALLEL=4 bash $(basename "$0")）"

# ---------- 4.5 跑完先体检，再计分 ----------
done_n=$(ls -1 "$RESULT_DIR"/actions/*.json 2>/dev/null | wc -l || true)
say "已写出结果文件: ${done_n:-0} / $total 条（目录 $RESULT_DIR/actions/）"
if [[ "$RUN_OK" -ne 0 ]]; then
  warn "run.py 非零退出，说明并非所有任务都正常跑完。先看下面的线索，然后照样计分："
fi
if [[ "${done_n:-0}" -lt "$total" ]]; then
  warn "结果文件少于任务数，常见原因见下面日志："
  if [[ -f "$RESULT_DIR/error.txt" ]]; then
    warn "=== $RESULT_DIR/error.txt 末尾 30 行 ==="
    tail -n 30 "$RESULT_DIR/error.txt"
  fi
  if [[ "$PARALLEL" -gt 1 ]]; then
    for f in logs/chunk_*.log; do
      [[ -f "$f" ]] || continue
      warn "=== $f 末尾 10 行 ==="
      tail -n 10 "$f"
    done
  fi
  warn "若日志是登录失败/断言错误 → 检查 PYTHON 与 PATH 里的 python 是否同一环境；"
  warn "若日志是模型 4xx/超时 → 核对顶部模型配置区的 PLANNER_IP 与 MODEL 写法。"
fi

# ---------- 5. 计分 ----------
# 计分无条件执行：即使上面有任务失败，也先把已完成部分的准确率算出来。
echo
SCORE_RC=0
"$PYTHON" scripts/score_subset.py --result_dir "$RESULT_DIR" --task_dir "$TASK_DIR" --show-failed || SCORE_RC=$?
if [[ $SCORE_RC -ne 0 ]]; then
  warn "计分脚本返回 $SCORE_RC（最常见是「还没有完成任何任务」，即没有一条任务跑成功）"
fi

cat <<EOF

  结果目录 : $RESULT_DIR
  任务集   : $TASK_DIR
  模型     : $MODEL  ($PLANNER_IP)
  单条重跑 : $PYTHON run.py --test_config_base_dir $TASK_DIR \\
               --test_start_idx <序号> --test_end_idx <序号+1> ...（其余参数见本脚本）
  纯计分   : bash $(basename "$0") --score-only
  完整重跑 : bash $(basename "$0")   （每次都是全量 35 条，旧结果自动备份）
EOF
