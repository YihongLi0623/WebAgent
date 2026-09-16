#!/bin/bash
# ==============================================================================
# 多模态评测：shopping_admin 单站点，把「简化 HTML 文本 + 页面截图」一起喂给模型
#
# 与 eval/evaluate_shopping_admin.sh 的关系
# ----------------------------------------
#   * 纯文本基线脚本**完全没有被改动**，仍在原地、仍可独立运行。
#   * 本脚本不调用它，而是调 multimodal_eval/run_multimodal.py（同样是新文件）。
#   * 两者唯一的差异就是：模型多看到一张当前页截图。模型、任务集、
#     登录流程、动作空间（webrl_id）、观测文本（WebRL 简化 HTML）全部相同，
#     所以两次结果的差可以直接归因到「截图」。
#
# 用法
# ----
#   bash multimodal_eval/evaluate_shopping_admin_multimodal.sh              # 全量 35 条
#   LIMIT=3 bash multimodal_eval/evaluate_shopping_admin_multimodal.sh      # 先跑 3 条
#   PARALLEL=4 bash ...                                                     # 4 进程并行
#   bash multimodal_eval/evaluate_shopping_admin_multimodal.sh --smoke      # 只跑冒烟测试
#   bash multimodal_eval/evaluate_shopping_admin_multimodal.sh --score-only # 只重新计分
#   bash multimodal_eval/evaluate_shopping_admin_multimodal.sh --compare    # 与纯文本基线对比
#
# 前置条件（与纯文本评测完全一致）
#   - shopping_admin 容器已起（WebArena-Env-Setup/start_shopping_admin.sh）
#   - conda 环境已激活，且 PYTHON 与 PATH 里的 python 是同一个
#     （run.py:405 的登录子进程硬编码了裸 "python"）
#   - 评测机与容器同机（任务 JSON 里写死 localhost:8083）
# ==============================================================================

set -euo pipefail

# ============================ 路径配置区 =====================================
# 允许环境变量覆盖：PYTHON=/path/to/venv/bin/python bash $0
# （注意：若设成绝对路径，PATH 里也得有同环境的 python —— run.py:405 的登录子进程
#   硬编码了裸 "python"，下面的前置检查会拦住不一致的情况）
PYTHON="${PYTHON:-python}"

MM_DIR="multimodal_eval"
TASK_SRC_DIR="config_files/wa/test_webarena_lite"          # 165 条全集
TASK_DIR="${MM_DIR}/configs/shopping_admin"                # 筛后目标集（0..34.json 连续编号）
RESULT_DIR="${MM_DIR}/results/shopping_admin_multimodal"   # 本次实验结果
INSTRUCTION_PATH="${MM_DIR}/prompts/p_multimodal_webrl_chat_think.json"
# 纯文本基线结果目录，只用于 --compare
BASELINE_RESULT_DIR="${BASELINE_RESULT_DIR:-eval_results/shopping_admin_qwen3.8-27b-quasar}"

# ============================ 站点配置区 =====================================
SITE="shopping_admin"
PUBLIC_HOSTNAME="localhost"      # 任务 JSON 里写死 localhost:8083，别乱改
SHOPPING_ADMIN_PORT=8083

# ============================ 模型配置区 =====================================
# 与纯文本基线用的是同一个端点 —— 只有 prompt 里多了图像，其它都不变。
PROVIDER="openai"
MODEL="${MM_MODEL:-QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4}"
MODE="chat"
PLANNER_IP="${MM_PLANNER_IP:-https://inference.cluster.aimodelnetwork.cn/QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4/v1}"
OPENAI_API_KEY="${OPENAI_API_KEY:-EMPTY}"
# 判分（fuzzy_match / ua_match）不走 planner_ip，单独读 OPENAI_API_URL
OPENAI_API_URL="${OPENAI_API_URL:-https://inference.cluster.aimodelnetwork.cn/QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4/v1}"
export JUDGE_MODEL="${JUDGE_MODEL:-QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4}"
export JUDGE_MAX_TOKENS="${JUDGE_MAX_TOKENS:-2048}"
STOP_TOKEN="<|im_end|>"

# ============================ 多模态开关 =====================================
# 显式开关：防止误把带图请求打到不支持图像的模型上（run_multimodal.py 会校验）
MM_MULTIMODAL=1
MM_TEXT_OBS="webrl"              # 文本观测：WebRL 简化 HTML（与基线一致）
MM_IMAGE_OBS="image"             # 图像观测：纯截图。不能改成 image_som ——
                                 # SoM 会返回说明文本并覆盖掉 HTML，见 mm_patches.py
MM_IMAGE_NOTE="${MM_IMAGE_NOTE:-** Screenshot of current page **}"
MM_IMAGE_FIRST="${MM_IMAGE_FIRST:-0}"       # 1 = 截图放在 HTML 文本之前
MM_HISTORY_IMAGES="${MM_HISTORY_IMAGES:-0}" # 1 = 历史轮也带当时的截图（token 翻倍）
MM_MAX_IMAGE_SIDE="${MM_MAX_IMAGE_SIDE:-0}" # >0 则等比缩放到该长边上限
MM_DUMP_PROMPT="${MM_DUMP_PROMPT:-0}"       # 1 = 落盘一份实际发出的 prompt 样本

# ============================ 运行配置区 =====================================
LIMIT=0            # 只跑前 N 条（0=全部）
PARALLEL=1         # 并发进程数。带图后每请求 payload 变大，别一上来就开很大
REFRESH_AUTH=1
FRESH_RUN=1        # 1 = 把旧结果改名备份后完整重跑（理由同纯文本脚本）
MAX_STEPS=30
TEMPERATURE=1.0
MAX_TOKENS=4096    # 思考模型的思维链也算 completion token
MAX_OBS_LENGTH=0
VIEWPORT_WIDTH=1280
VIEWPORT_HEIGHT=720
ACTION_SET_TAG="webrl_id"
OBSERVATION_TYPE="webrl"

# =============================================================================

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say()  { echo -e "\033[1;35m[mm]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }
trap 'rc=$?; echo -e "\033[1;31m[error]\033[0m 第 $LINENO 行失败（退出码 $rc）: $BASH_COMMAND" >&2' ERR

MODE_ARG="${1:-}"

# ---------- 环境变量 ----------
export DATASET="webarena"
export SHOPPING_ADMIN="http://${PUBLIC_HOSTNAME}:${SHOPPING_ADMIN_PORT}/admin"
export SHOPPING="http://127.0.0.1:1"
export REDDIT="http://127.0.0.1:1"
export GITLAB="http://127.0.0.1:1"
export WIKIPEDIA="http://127.0.0.1:1"
export MAP="http://127.0.0.1:1"
export HOMEPAGE="http://127.0.0.1:1"
export OPENAI_API_KEY OPENAI_API_URL
export PYTHONUNBUFFERED=1     # 否则 `| tee` 会让 Action String 变块缓冲、看起来像"没打印"
# 传给 run_multimodal.py / mm_patches.py 的多模态开关
export MM_MULTIMODAL MM_TEXT_OBS MM_IMAGE_OBS MM_IMAGE_NOTE MM_IMAGE_FIRST \
       MM_HISTORY_IMAGES MM_MAX_IMAGE_SIDE MM_DUMP_PROMPT
export MM_PLANNER_IP="$PLANNER_IP" MM_MODEL="$MODEL"

# ---------- --smoke：不需要浏览器/站点 ----------
if [[ "$MODE_ARG" == "--smoke" ]]; then
  say "运行多模态冒烟测试（不连站点、不连模型）…"
  "$PYTHON" "${MM_DIR}/smoke_test_multimodal.py"
  exit $?
fi

# ---------- --compare：与纯文本基线逐条对比 ----------
if [[ "$MODE_ARG" == "--compare" ]]; then
  "$PYTHON" "${MM_DIR}/compare_modal_results.py" \
    --text-dir "$BASELINE_RESULT_DIR" \
    --mm-dir "$RESULT_DIR" \
    --task-dir "$TASK_DIR" \
    --show-intent
  exit $?
fi

# ---------- --score-only ----------
if [[ "$MODE_ARG" == "--score-only" ]]; then
  [[ -d "$TASK_DIR" ]] || die "任务目录不存在: $TASK_DIR，先跑一次完整流程"
  "$PYTHON" scripts/score_subset.py --result_dir "$RESULT_DIR" --task_dir "$TASK_DIR" --show-failed
  exit $?
fi

# ---------- 0. 前置检查 ----------
if [[ "$PYTHON" != "python" ]]; then
  p_target="$("$PYTHON" -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
  p_path="$(command -v python 2>/dev/null || true)"
  if [[ -z "$p_path" ]]; then
    warn "PATH 里没有 python，而 run.py:405 的登录子进程硬编码了 \"python\""
  elif [[ -n "$p_target" && "$p_target" != "$p_path" ]]; then
    die "PYTHON 与 PATH 里的 python 不是同一个环境：
    PYTHON = $p_target
    python = $p_path
  登录子进程用的是裸 \"python\"，不一致会让逐任务登录失败。
  解决：先 conda activate <环境>，再把 PYTHON 设回 "python""
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

# 端点预检：这次实验的关键前提是模型真能收图，不通就别浪费 35 条任务的时间
if [[ -n "$PLANNER_IP" && "${SKIP_MODEL_CHECK:-0}" != "1" ]]; then
  say "检查模型端点与图像输入能力…"
  "$PYTHON" "${MM_DIR}/check_vision_endpoint.py" || die \
"模型端点预检失败。这次评测全靠图像输入，请先解决上面这个问题。
  想强行跳过: SKIP_MODEL_CHECK=1 bash $0"
fi

# ---------- 1. 生成任务集（与纯文本基线用的是同一套筛选逻辑） ----------
if [[ ! -d "$TASK_DIR" ]]; then
  say "任务目录不存在，正在生成…"
  "$PYTHON" scripts/filter_tasks_by_site.py --src "$TASK_SRC_DIR" --dst "$TASK_DIR" \
    --site "$SITE" --host "$PUBLIC_HOSTNAME"
else
  n=$(ls -1 "$TASK_DIR"/*.json 2>/dev/null | wc -l || true)
  say "复用已有任务目录 $TASK_DIR（$n 条）"
fi

# ---------- 2. 备份旧结果，确保全量重跑 ----------
if [[ "$FRESH_RUN" == "1" && -d "$RESULT_DIR" ]]; then
  backup="${RESULT_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
  say "备份上次结果: $RESULT_DIR -> $backup"
  mv "$RESULT_DIR" "$backup"
  warn "旧结果已备份到 $backup（不需要就自己删）"
fi

total=$(ls -1 "$TASK_DIR"/*.json 2>/dev/null | wc -l || true)
[[ "$total" -gt 0 ]] || die "任务目录里没有任务: $TASK_DIR"
if [[ "$LIMIT" -gt 0 && "$LIMIT" -lt "$total" ]]; then
  warn "LIMIT=$LIMIT，本次只跑前 $LIMIT 条（不是完整 $total 条）"
  total="$LIMIT"
fi
say "本次将跑 $total 条任务"

# ---------- 3. 刷新并验证登录 cookie ----------
if [[ "$REFRESH_AUTH" == "1" ]]; then
  say "刷新 $SITE 登录 cookie…"
  mkdir -p .auth
  if "$PYTHON" browser_env/auto_login.py --site_list "$SITE" --auth_folder ./.auth; then
    if "$PYTHON" scripts/check_login.py --state-file "./.auth/${SITE}_state.json"; then
      say "登录有效"
    else
      die "登录无效！35 条里有 14 条（program_html / url_match）需要已登录上下文，
  否则会静默得 0 分。确认要跳过: REFRESH_AUTH=0 bash $0"
    fi
  else
    warn "cookie 刷新失败；run.py 会按任务自己重新登录，建议先解决上面的报错"
  fi
fi

mkdir -p "$RESULT_DIR" logs

# ---------- 4. 跑评测 ----------
run_chunk() {
  local start="$1" end="$2"
  "$PYTHON" "${MM_DIR}/run_multimodal.py" \
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

say "模型   : $MODEL  → $PLANNER_IP"
say "模板   : $INSTRUCTION_PATH"
say "观测   : 文本=$MM_TEXT_OBS（简化 HTML） + 图像=$MM_IMAGE_OBS（截图）"
say "附加项 : 历史轮带图=$MM_HISTORY_IMAGES  截图在前=$MM_IMAGE_FIRST  缩放上限=$MM_MAX_IMAGE_SIDE"
say "任务   : $TASK_DIR / 本次 $total 条 / 并发 $PARALLEL"
say "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
START_TS=$SECONDS

RUN_OK=1
if [[ "$PARALLEL" -le 1 ]]; then
  run_chunk 0 "$total" 2>&1 | tee "logs/mm_run_$(date +%Y%m%d-%H%M%S).log" || RUN_OK=0
else
  chunk=$(( (total + PARALLEL - 1) / PARALLEL ))
  pids=()
  for ((i = 0; i < PARALLEL; i++)); do
    s=$((i * chunk))
    if [[ $s -ge $total ]]; then break; fi
    e=$((s + chunk))
    if [[ $e -gt $total ]]; then e=$total; fi
    say "  进程 $i: 任务 [$s, $e)  共 $((e - s)) 条  → logs/mm_chunk_${i}.log"
    run_chunk "$s" "$e" >"logs/mm_chunk_${i}.log" 2>&1 &
    pids+=($!)
  done
  RUN_OK=0
  for pid in "${pids[@]}"; do
    wait "$pid" || RUN_OK=1
  done
fi

say "结束时间: $(date '+%Y-%m-%d %H:%M:%S')   总耗时 $((SECONDS - START_TS)) 秒"

# ---------- 4.5 体检 ----------
done_n=$(ls -1 "$RESULT_DIR"/actions/*.json 2>/dev/null | wc -l || true)
say "已写出结果文件: ${done_n:-0} / $total 条"
if [[ "$RUN_OK" -ne 0 ]]; then
  warn "run.py 非零退出，并非所有任务都正常跑完："
fi
if [[ "${done_n:-0}" -lt "$total" ]]; then
  if [[ -f "$RESULT_DIR/error.txt" ]]; then
    warn "=== $RESULT_DIR/error.txt 末尾 30 行 ==="
    tail -n 30 "$RESULT_DIR/error.txt"
  fi
  for f in logs/mm_chunk_*.log; do
    [[ -f "$f" ]] || continue
    warn "=== $f 末尾 10 行 ==="
    tail -n 10 "$f"
  done
  warn "若报 400 / 图像相关错误 → 端点不支持这种 content 格式；"
  warn "若报解析失败 → 图 + 文本一起进 prompt 后输出可能跑格式，考虑调 MAX_TOKENS 或换模板。"
fi

# ---------- 5. 计分 ----------
echo
SCORE_RC=0
"$PYTHON" scripts/score_subset.py --result_dir "$RESULT_DIR" --task_dir "$TASK_DIR" --show-failed || SCORE_RC=$?
if [[ $SCORE_RC -ne 0 ]]; then
  warn "计分脚本返回 $SCORE_RC（最常见是「还没有完成任何任务」）"
fi

# ---------- 6. 与纯文本基线对比 ----------
if [[ -d "$BASELINE_RESULT_DIR/actions" ]]; then
  echo
  say "与纯文本基线对比（$BASELINE_RESULT_DIR）："
  "$PYTHON" "${MM_DIR}/compare_modal_results.py" \
    --text-dir "$BASELINE_RESULT_DIR" \
    --mm-dir "$RESULT_DIR" \
    --task-dir "$TASK_DIR" || warn "对比失败（不影响上面的计分结果）"
else
  echo
  warn "没找到纯文本基线结果目录 $BASELINE_RESULT_DIR/actions，跳过对比。"
  warn "先跑一次纯文本评测，或用 BASELINE_RESULT_DIR=<你的目录> 指定。"
fi

cat <<EOF

  多模态结果 : $RESULT_DIR
  纯文本基线 : $BASELINE_RESULT_DIR
  任务集     : $TASK_DIR
  单条重跑   : $PYTHON ${MM_DIR}/run_multimodal.py --test_config_base_dir $TASK_DIR \\
                 --test_start_idx <序号> --test_end_idx <序号+1> ...（其余参数见本脚本）
  纯计分     : bash ${MM_DIR}/$(basename "$0") --score-only
  结果对比   : bash ${MM_DIR}/$(basename "$0") --compare
  冒烟测试   : bash ${MM_DIR}/$(basename "$0") --smoke
  prompt样本 : MM_DUMP_PROMPT=1 bash ${MM_DIR}/$(basename "$0")   → ${MM_DIR}/debug/
EOF
