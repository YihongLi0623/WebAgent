# WebAgent / WebAgent-R1 项目长期笔记

## 环境事实
- 评测**必须跑在容器所在的那台 Linux 机器**上：任务 JSON 里 `start_url`/`reference_url`
  全部硬编码 `http://localhost:8083/...`（34 处 start_url + 一批 reference_url）。
  跨机评测要把 `PUBLIC_HOSTNAME` 改成容器 IP，让 `filter_tasks_by_site.py --host` 重写任务 URL。
- 当前开发机（Windows）跑不了评测：无 docker/playwright/torch。仓库代码在 Windows，运行在 Linux。
- Eval 依赖 `run.py:487` 的 `page.screenshot(path="/dev/null")`（预热截图），Windows 上直接报错。

## 已产出/改造的脚本（都在 `WebAgent-R1/`）
- `WebArena-Env-Setup/start_shopping_admin.sh`：只起 shopping_admin 单站点的容器脚本。
  注意 `${TAR_FILE:-默认}` 那个 `-` 不能少；里面的 patch（`password_is_forced 0`、
  `password_lifetime 0`）是自动登录能成立的前提，单跑 docker start 不够。
- `Eval/scripts/filter_tasks_by_site.py`：按 `sites` 字段筛任务并**重排文件名成 0..N-1**，
  保留 JSON 内部原始 task_id。支持 `--mode any|single`、`--limit`、`--ids`、
  `--exclude-done`、`--host`（重写 URL 主机名）。
- `Eval/scripts/score_subset.py`：子集计分。`score.py` 把总数写死 165，跑子集会算错。
- `Eval/scripts/check_login.py`：真开一次 `/admin/dashboard` 验证登录，
  因为 `auto_login.py --site_list` 分支跳过 `is_expired` 校验。
- `Eval/evaluate_shopping_admin.sh`：一站式（筛任务 + 模型配置 + 登录验证 + 跑 + 计分）。

## 必须知道的机制/坑
- `run.py` 取任务是**连续编号硬编码**（`{i}.json`），不能靠 start/end_idx 跳选站点。
- `run.py:671` 自己会调 `get_unfinished()` 跳过"已完成"任务，判据用**文件名序号**查
  `actions/{序号}.json` + `render_*.html` 反推。对重排过的目录判据不成立 →
  脚本用 `FRESH_RUN=1` 每次把结果目录改名备份，让 run.py 看到空目录、全量重跑。
- 登录由 `run.py` 每任务调 `auto_login.py` 现场做（写临时目录并改写该任务的 storage_state）。
  任务 JSON 里的 `./.auth/shopping_admin_state.json` **只取文件名**推导站点组合，内容从不读。
  `require_login` 字段 Eval 侧无代码读取。35 条里有 14 条（program_html / url_match）
  没有登录态会**静默得 0 分**。
- `run.py:405` 登录子进程硬编码字符串 `"python"`（不是 `sys.executable`）且没 `check=True`
  → `PYTHON` 必须与 PATH 里的 `python` 同环境，否则逐任务登录失败被 except 吞掉。
- 模型侧：`agent.py:176` 是唯一分叉 —— `planner_ip` 非空则 `call_llm(api_key='EMPTY', base_url=planner_ip)`，
  否则走 `OPENAI_API_URL`。`OPENAI_API_KEY` 无论走哪条路都必须 export（import 阶段就 KeyError）。
  provider `openai` + `MODE=chat` 时 `stop_token` 被硬编码成 None（`llms/utils.py:37`）。
- 观测协议：`OBSERVATION_TYPE=webrl`（读无障碍树文本）+ `ACTION_SET_TAG=webrl_id`。
  WebRL chat prompt 构造器只拼文本 obs，**不送图**。
- 截图/产物：`{result_dir}/screehshots/{task_id}/{i}.png`（注意拼写少个 n，是 0-based step 号，
  在 `env.step` **之前**拍，viewport 尺寸）；绿框是 OpenCV 后处理画的，靠 DOM 注入的
  `data-label-id`，下轮被清理。另有 `render_{task_id}.html`（内嵌 base64）、
  `traces/{task_id}.zip`（Playwright 原生 trace，含 DOM 快照）、`debug_info/`（每步覆盖）。
  `args.render/render_screenshot/save_trace_enabled` 在 run.py:673-675 被写死，命令行关不掉。
- 评测模型最好**多探测一下再配**：先 `/v1/models` 确认 base_url 形态与精确 model id，
  再发一次最小 chat 请求看鉴权/是否 reasoning 模型/是否多模态。模型名常在 URL 路径里。

## 判分（LLM-as-judge）—— 和 agent 模型是两套
- 只有 `fuzzy_match` / `ua_match` 两种 eval 类型会调 LLM 判分：
  `evaluation_harness/helper_functions.py` 的 `llm_fuzzy_match` / `llm_ua_match`，
  **不经过 `--planner_ip`**，独立走 `OPENAI_API_URL` + `OPENAI_API_KEY` + `JUDGE_MODEL`。
- 原代码写死 `model="gpt-4-1106-preview"`。已改成 `JUDGE_MODEL`（默认
  `QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4`）+ `JUDGE_MAX_TOKENS`（默认 2048），
  `evaluate_shopping_admin.sh` 里 export 这两个并让 `OPENAI_API_URL` 指向同一个 vLLM 网关。
- 判分 prompt 要求只输出 `correct`/`incorrect`/`partially correct`（ua_match 是
  `same`/`different`），代码里有 `assert "correct" in response` —— 跑格式会让断言失败、
  任务被吞掉不计分。实测该 Qwen 网关三种用例都按格式返回，且只用 60-80 tokens。
- 判分失败会让任务**不写 score**（`actions/<id>.json` 停在 -0.1）→ 被算"未跑"而不是失败。

## 用户偏好
- 交流要直接简洁；不要主动替用户跑长任务（本地环境也跑不了），
  用户会自己改脚本里的路径/参数后在 Linux 上跑。
