# 多模态评测：HTML 文本 + 页面截图

把**简化 HTML 文本**和**当前页截图**一起送进模型，用来对照纯文本基线看多模态输入的效果。

本目录下的所有文件都是新增的，**没有修改 `Eval/` 下的任何原有文件**（详见文末「未改动清单」）。

---

## 1. 这个实验到底改了什么

| 环节 | 纯文本基线 | 本实验 |
|---|---|---|
| 文本观测 | WebRL 简化 HTML（`TextObervationProcessorWebRL`） | **完全相同** |
| 图像观测 | 不产出（`image_observation_type=""`） | 产出 viewport 截图（`"image"`） |
| 送进模型的 prompt | `intro` + 历史轮（HTML 省略成占位符）+ 当前轮 HTML | 同上，**仅当前轮多一张截图** |
| 动作空间 | `webrl_id` | **完全相同** |
| 模型 / 端点 / 温度 / max_steps / 任务集 / 登录流程 | — | **完全相同** |

所以两次评测的差可以单独归因到「模型多看到了一张截图」，这是这个目录存在的全部意义。

---

## 2. 为什么不用改原文件也能做到

原仓库其实**每一环都已具备**，只是没被同时打开。缺的只有三处，全部可以用运行时补丁补上：

```
① browser_env/processors.py  ObservationHandler.__init__
     envs.py:110 在 observation_type=webrl 时把 image_observation_type 置成 ""
     → 补丁改成 "image"，于是每步都会产出截图
       注意必须是 "image" 而不是 "image_som"：
       ImageObservationProcessor 在 image_som 下会返回 SoM 说明文本，而
       ObservationHandler.get_observation 里有
           if content_str != "": text_obs = content_str
       会把我们的 HTML **覆盖掉**。

② agent/agent.py  PromptAgent.__init__
     第 124 行的判定是
       (… or provider in ["api","finetune"]) and type(pc) == MultimodalCoTPromptConstructor
     我们的构造器是子类，`type(...) ==` 过不了
     → 补丁里直接置 multimodal_inputs = True（只对我们的构造器生效）

③ agent/agent.py 的模块命名空间
     construct_agent 用 eval(constructor_type) 按名字解析类，
     eval 的 globals 就是 agent.agent 的模块字典
     → 补丁把我们的类名注入那个命名空间
```

**不补丁、因此行为不变的部分**：`env.step` 仍走 `execute_action_webrl`
（`env.text_observation_type` 仍是 `"webrl"`）、动作仍是 `create_webrl_id_based_action`、
`traces/{task_id}.jsonl` 仍会写、`render_{task_id}.html` 与截图目录照旧。

补丁的实现全在 [`mm_patches.py`](mm_patches.py)，每一处都写了「为什么」。

---

## 3. 目录结构

```
multimodal_eval/
├── mm_prompt_constructor.py        # MultimodalWebRLPromptConstructor
│                                   #   继承原 WebRLChatPromptConstructor，只追加图像块
├── mm_patches.py                   # 三处运行时补丁 + 可选的 prompt 取样
├── run_multimodal.py               # 入口：打补丁后 runpy 执行原封不动的 run.py
├── prompts/
│   └── p_multimodal_webrl_chat_think.json   # 模板（intro 加了截图说明，
│                                            #   prompt_constructor 指向我们的类）
├── evaluate_shopping_admin_multimodal.sh    # 一站式：预检→筛任务→登录→跑→计分→对比
├── smoke_test_multimodal.py        # 冒烟测试：不需要浏览器/模型端点
├── check_vision_endpoint.py        # 预检端点是否真的收图（只用标准库）
├── compare_modal_results.py        # 纯文本 vs 多模态 逐条对比
├── configs/                        # 生成的任务集（运行后出现）
├── results/                        # 结果（运行后出现）
└── debug/                          # MM_DUMP_PROMPT=1 时落盘的 prompt 样本
```

---

## 4. 快速开始

```bash
cd WebAgent-R1/Eval
conda activate webagent-r1          # 与纯文本评测同一个环境

# 0) 先跑冒烟测试（10 秒，验证补丁 + prompt 结构，不连站点不连模型）
bash multimodal_eval/evaluate_shopping_admin_multimodal.sh --smoke

# 1) 先跑 3 条试水
LIMIT=3 bash multimodal_eval/evaluate_shopping_admin_multimodal.sh

# 2) 全量 35 条
bash multimodal_eval/evaluate_shopping_admin_multimodal.sh

# 3) 与纯文本基线对比（基线默认取 eval_results/shopping_admin_qwen3.8-27b-quasar）
bash multimodal_eval/evaluate_shopping_admin_multimodal.sh --compare
```

前置条件和纯文本评测完全一致：容器在跑、评测机与容器同机、`PYTHON` 与 `PATH` 里的
`python` 是同一个环境（`run.py:405` 的登录子进程硬编码了裸 `python`）。

---

## 5. 可调开关（环境变量）

| 变量 | 默认 | 作用 |
|---|---|---|
| `MM_MULTIMODAL` | 必须为 `1` | 显式总开关。`run_multimodal.py` 会拦住未开启的情况，防止误把带图请求打到纯文本模型上 |
| `MM_IMAGE_NOTE` | `** Screenshot of current page **` | 截图前的提示文字 |
| `MM_IMAGE_FIRST` | `0` | `1` = 截图放在 HTML **之前**（更接近原 WebArena SoM 协议的顺序） |
| `MM_HISTORY_IMAGES` | `0` | `1` = 历史轮也带上各自当时的截图。历史轮的 HTML 被原实现省略成占位符，所以补图信息量更大，但图像数 = 步数，token 明显上升 |
| `MM_MAX_IMAGE_SIDE` | `0` | `>0` 时等比缩放到该长边上限（1280×720 的 PNG 约 200~400KB，base64 后 ×1.37） |
| `MM_DUMP_PROMPT` | `0` | `1` = 把每个进程**实际发出的第一份 prompt** 落盘到 `debug/`（json 摘要 + 配套 png） |
| `MM_TEXT_OBS` / `MM_IMAGE_OBS` | `webrl` / `image` | 观测类型，一般不用动 |
| `MM_PLANNER_IP` / `MM_MODEL` | 同脚本顶部 | 模型端点与 id |
| `MM_DRY_RUN` | `0` | `1` = 打完补丁、拼好参数就停下，**不执行 run.py**。用来快速确认参数/模板/补丁链路 |
| `PYTHON` | `python` | 解释器路径，可用环境变量覆盖（记得 `PATH` 里要有同环境的 `python`） |

示例：

```bash
# 历史轮也带图
MM_HISTORY_IMAGES=1 bash multimodal_eval/evaluate_shopping_admin_multimodal.sh

# 落盘一份 prompt 样本，肉眼确认图真的进去了
MM_DUMP_PROMPT=1 LIMIT=1 bash multimodal_eval/evaluate_shopping_admin_multimodal.sh
ls multimodal_eval/debug/

# 只验证链路（不发请求、不开浏览器）
MM_DRY_RUN=1 python multimodal_eval/run_multimodal.py --test_start_idx 0 --test_end_idx 3
```

---

## 6. 怎么确认「图真的进了模型」

三道独立的证据，从强到弱：

1. **`debug/` 里的 prompt 样本**（最直接）
   `MM_DUMP_PROMPT=1` 会写出 `mm_prompt_sample_*.json`（列出每条消息、文本长度、
   有几个 image 块、base64 长度）和同名 `.png`（那张被送进去的截图本身）。

2. **`logs/mm_run_*.log` 里的 `[mm]` 行**
   ```
   [mm] 已应用运行时补丁：
   [mm]   - ObservationHandler.__init__ -> image_observation_type='image'
   [mm]   - agent.agent.MultimodalWebRLPromptConstructor 已注册（供 eval() 解析）
   [mm]   - PromptAgent.__init__ -> multimodal_inputs=True（仅对本构造器）
   ```
   只要这三行都在，观测链路就是通的。

3. **端点预检**：脚本开跑前会真的发一张 1×1 PNG 给模型（`check_vision_endpoint.py`），
   端点拒收图像会直接退出，不会让你等 35 条任务跑完才发现。

---

## 7. 常见问题

**Q: 报 400 / "image" 相关错误？**
端点不支持这种 content 格式。先手动跑 `python multimodal_eval/check_vision_endpoint.py` 定位。
本次实验必须用**多模态模型**；纯文本模型（如 llama.cpp 上的 llama3.1-8B）会直接失败。

**Q: 每步变慢、或者 vLLM 报 OOM？**
图像会显著增加 prompt token。可先 `MM_MAX_IMAGE_SIDE=640` 缩小，或把 `PARALLEL` 降到 1。

**Q: 解析失败（`parsing_failure_th`）变多了？**
图 + 长 HTML 一起进 prompt 时，小模型更容易跑格式。依次尝试：
① `MAX_TOKENS` 提到 8192；② `TEMPERATURE=0.6`；③ `MM_IMAGE_FIRST=1` 把图放前面。

**Q: 历史轮的 HTML 为什么是 `** Simplified html **` 而不是真 HTML？**
这是原 `WebRLChatPromptConstructor` 的设计（`prompt_constructor.py:606-612`），
本实验**刻意保留**，这样和纯文本基线的文本部分逐字节一致。

**Q: 分数和论文里的 WebArena 数字能直接比吗？**
不能。① 判分模型换成了 Qwen3.8-27B 而不是 GPT-4；
② 任务集是 WebArena-Lite 的 shopping_admin 子集（35 条）；
③ 加了截图属于自定义协议。跨模型比较请在**同一批 35 条 + 同一判分模型**下做。

**Q: 翻转条数只有个位数，说明什么？**
`TEMPERATURE=1.0` 下同一条任务重跑本身就会波动。要下结论建议固定 `TEMPERATURE=0`
或每条重复 3 次看均值。

---

## 8. 未改动清单

以下文件**一个字节都没动**（补丁全部在运行时生效）：

- `run.py`
- `agent/agent.py`、`agent/prompts/prompt_constructor.py`、`agent/prompts/jsons/*`
- `browser_env/*.py`（含 `envs.py`、`processors.py`）
- `evaluate_shopping_admin.sh`（纯文本基线脚本，仍可独立运行）

被**复用/调用**的未改动文件：`scripts/filter_tasks_by_site.py`、
`scripts/check_login.py`、`scripts/score_subset.py`、`browser_env/auto_login.py`。
