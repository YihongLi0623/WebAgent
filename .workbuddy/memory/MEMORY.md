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
- 观测协议：`OBSERVATION_TYPE=webrl` + `ACTION_SET_TAG=webrl_id`。**喂给模型的是"简化 HTML 文本"，
  不是无障碍树、也不是原始 DOM**：`TextObervationProcessorWebRL.process`（processors.py:1219-1253）
  返回 `get_parsed_html(page)["html"]` —— `modify_page()` 先给活 DOM 注入 `data-bbox` /
  `data-label-id`，再由 `HtmlParser` 以 `prompt="xml"`、`attr_list=basic_attrs` 输出简化 XML 式 HTML。
  prompt 侧 `PromptConstructor.obs_modality="text"` 写死（prompt_constructor.py:32），
  WebRLChatPromptConstructor 只拼 `Round N\n\n{obs}`，**messages 里没有任何图像块**。
- **截图不进模型**，全部只用于留档/人工查看。每步实际有 **4 次** `page.screenshot()`：
  ① `debug_info/screenshot_raw.png` ② `debug_info/marked.png`（都在 html_tools/fetch.py:31/48，
  每步覆盖）③ `ImageObservationProcessor.process`（processors.py:1153）→ 进内存的
  `observation["image"]`，只被 RenderHelper base64 内嵌到 `render_<task_id>.html`
  ④ `run.py:485-488` 存进 `screehshots/<task_id>/{step}.png`（这张才有 OpenCV 绿框）。
  `ObservationHandler.get_observation`（1330-1335）**无条件**同时跑文本+图像处理器，
  所以 webrl 下也会拍。另外 `run.py:326-358`：captioner 只在
  `observation_type=accessibility_tree_with_captioner` 且 `DATASET=visualwebarena` 时才加载，
  我们 `DATASET=webarena` → `caption_image_fn`/`eval_caption_image_fn` 都是 None，
  不会去下载 blip2；`agent.py:124` 的 `multimodal_inputs` 对 provider=openai 也是 False。
- 产物：`screehshots/.../{i}.png`（注意拼写少个 n，0-based step 号，`env.step` **之前**拍）、
  `render_{task_id}.html`、`traces/{task_id}.zip`（Playwright trace，含 DOM 快照）、
  `debug_info/`（每步覆盖）。`args.render/render_screenshot/save_trace_enabled` 在
  run.py:673-675 被写死，命令行关不掉。
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

## 多模态观测（截图 + HTML）—— `Eval/multimodal_eval/`（新增，不改原文件）

- 目标：只把「模型多看到一张当前页截图」作为唯一变量；文本观测、动作空间、模型、
  任务集、登录流程全部与纯文本基线一致，两次结果之差可归因到截图。
- 实现是**三处运行时补丁**（`mm_patches.py`），不需要动任何原文件：
  ① `ObservationHandler.__init__`：把 `image_observation_type` 从 `""` 改成 `"image"`。
     **必须是 `"image"` 不能是 `"image_som"`** —— SoM 会让
     `ImageObservationProcessor.process` 返回说明文本，而
     `get_observation` 里 `if content_str != "": text_obs = content_str` 会把 HTML 覆盖掉。
  ② `PromptAgent.__init__`：`agent.py:124` 是 `type(pc) == MultimodalCoTPromptConstructor`
     精确类型判断，子类过不了 → 补丁直接置 `multimodal_inputs=True`（只对我们的类生效）。
  ③ 把新类名注入 `agent.agent` 模块命名空间 —— `construct_agent` 用
     `eval(constructor_type)`，其 globals 就是 `agent.agent.__dict__`。
- **不需要**改 env：`--observation_type` 仍传 `webrl`，`env.text_observation_type` 保持
  `"webrl"` → `envs.py:283` 仍走 `execute_action_webrl`，`run.py:517` 仍写 jsonl trace。
  补丁只让 handler 多产出图像。这是最小侵入面。
- 新构造器 `MultimodalWebRLPromptConstructor` **继承** `WebRLChatPromptConstructor`，
  先调 super 拼出与原版逐字节相同的文本会话，再把最后一条 user 的 content 从 str
  升级成 `[text, image_url]` 列表 → 保证与基线可比。
- 踩过的坑：当前轮截图由 `agent.py:139-141` 传进来时是 **PIL 对象**，但历史轮只能从
  `trajectory[i]["observation"]["image"]` 取，那是 **numpy 数组** →
  直接 `pil_to_b64` 会抛 `'numpy.ndarray' object has no attribute 'save'`，
  被兜底降级成纯文本，表现为"开了 MM_HISTORY_IMAGES 却一张图都没有"。必须显式 `Image.fromarray`。
- `run_multimodal.py` 用 `runpy.run_path("run.py", run_name="__main__")` 执行原 run.py；
  必须先 `os.chdir(EVAL_DIR)`（run.py 全是相对路径）。参数用「缺则补默认、有则保留」，
  并硬校验 `--observation_type webrl` + `--action_set_tag webrl_id` + 模板的
  `meta_data.prompt_constructor == MultimodalWebRLPromptConstructor`，否则 exit 1。
- 配套工具：`smoke_test_multimodal.py`（20 项检查，不需要浏览器/端点）、
  `check_vision_endpoint.py`（纯标准库，发 1x1 PNG 验证端点收图）、
  `compare_modal_results.py`（逐条对比，标出 `^ 提升` / `v 退化` 翻转）。
- `evaluate_shopping_admin_multimodal.sh`：`--smoke` / `--score-only` / `--compare` 三种模式，
  结果与任务集都在 `multimodal_eval/` 下，不与纯文本基线冲突。
- 实测（2026-09-16）：该 vLLM 网关接受 `image_url`，1x1 白图能正确回答 "White"；
  补丁后的 prompt 确实带 1 个 `data:image/png;base64,` 块且 HTML 文本原样保留。

## 用户偏好
- 交流要直接简洁；不要主动替用户跑长任务（本地环境也跑不了），
  用户会自己改脚本里的路径/参数后在 Linux 上跑。
- 本机 Windows 装了隔离 venv `~/.workbuddy/binaries/python/envs/mmtest`（601MB，
  含 numpy/PIL/matplotlib/pandas/playwright/gymnasium/beartype/transformers…），
  专门用来跑 `multimodal_eval/smoke_test_multimodal.py`。注意两个本地环境事实：
  numpy 必须 `<2.4`（2.5.3 会让 beartype 解析 `npt.NDArray[np.uint8]` 失败）、
  pip 必须加 `--no-cache-dir`（否则 WorkBuddy 的 safe-delete 守卫会中断安装）。
