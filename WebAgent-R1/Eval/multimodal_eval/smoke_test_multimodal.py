#!/usr/bin/env python
"""多模态改动冒烟测试 —— 不需要浏览器，也不需要模型端点，10 秒内跑完。

    cd WebAgent-R1/Eval
    MM_MULTIMODAL=1 python multimodal_eval/smoke_test_multimodal.py

它验证四件事（任一条失败会直接非零退出，方便接进 CI 或你手动跑一遍确认）：
  1. `ObservationHandler` 补丁生效：文本仍是 webrl，但图像处理器变成了 "image"
     （`"image"` 而不是 `"image_som"` 很重要，否则 SoM 说明文本会覆盖掉 HTML）
  2. `PromptAgent.multimodal_inputs` 对我们的构造器为 True
  3. 真正发出的 chat messages 里，最后一条 user 消息带上了 base64 截图，
     且 HTML 文本原样保留（这样才和纯文本基线可比）
  4. 没有截图时能优雅退化成纯文本（不会崩）
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any

EVAL_DIR = Path(__file__).resolve().parent.parent
os.chdir(EVAL_DIR)
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))
os.environ.setdefault("MM_MULTIMODAL", "1")
os.environ.setdefault("OPENAI_API_KEY", "EMPTY")
# 只为让 browser_env/env_config.py 的非空断言通过 —— 本测试不起浏览器，不会用到这些地址
os.environ.setdefault("DATASET", "webarena")
for _var in ("SHOPPING_ADMIN", "SHOPPING", "REDDIT", "GITLAB", "WIKIPEDIA", "MAP", "HOMEPAGE"):
    os.environ.setdefault(_var, "http://127.0.0.1:1")

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

MM_DIR = Path(__file__).resolve().parent
TEMPLATE = MM_DIR / "prompts" / "p_multimodal_webrl_chat_think.json"

FAILURES: list[str] = []


def check(cond: bool, label: str, detail: str = "") -> None:
    mark = "PASS" if cond else "FAIL"
    print(f"  [{mark}] {label}" + (f"  ({detail})" if detail else ""))
    if not cond:
        FAILURES.append(label)


# ------------------------------------------------------------------ 构造假数据
FAKE_HTML = (
    '<html data-bbox="0,0,1280,720">'
    '<body><a data-label-id="0" href="/admin/reports">Reports</a>'
    '<button data-label-id="1" data-bbox="10,20,80,30">Sign Out</button>'
    "</body></html>"
)
INTENT = "Show me the top-3 best-selling products in Jan 2023"

# webrl_id 的动作语法（见 prompt intro 里的示例与 browser_env/actions.py:1979）：
#   do(action="Click", element="7")   ← element 是 data-label-id 的**字符串**编号
FAKE_ACTION = 'do(action="Click", element="7")'
FAKE_REPLY = (
    "<think>I should open the Reports page.</think>\n"
    f"<answer>{FAKE_ACTION}</answer>"
)


def make_image(seed: int = 0) -> Image.Image:
    arr = np.zeros((720, 1280, 3), dtype=np.uint8)
    arr[:, :] = (30 + (seed * 20) % 200, 40, 90)
    arr[100:140, 200:600] = (200, 200, 255)
    return Image.fromarray(arr)


def make_trajectory(n_rounds: int) -> list:
    from browser_env.actions import create_webrl_id_based_action
    from browser_env.utils import DetachedPage

    def state(round_idx: int):
        img = np.array(make_image(round_idx))
        return {
            "observation": {"text": FAKE_HTML, "image": img},
            "info": {
                "page": DetachedPage(f"http://localhost:8083/admin?r={round_idx}", ""),
                "fail_error": "",
                "observation_metadata": {},
            },
        }

    traj = [state(0)]
    for r in range(1, n_rounds):
        act = create_webrl_id_based_action(FAKE_ACTION)
        act["raw_prediction"] = f"<answer>{FAKE_ACTION}</answer>"
        traj.append(act)
        traj.append(state(r))
    return traj


def make_lm_config():
    from llms import lm_config

    return lm_config.LMConfig(
        provider="openai",
        model="QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4",
        mode="chat",
        gen_config={
            "temperature": 1.0,
            "top_p": 0.95,
            "context_length": 0,
            "max_tokens": 512,
            "stop_token": None,
            "max_obs_length": 0,  # 0 = 不截断，也就不用 tokenizer
            "max_retry": 1,
        },
    )


# -------------------------------------------------------------------- 各项检查
def test_observation_handler_patch() -> None:
    print("\n[1] ObservationHandler 补丁")
    from browser_env.processors import ObservationHandler

    viewport = {"width": 1280, "height": 720}
    handler = ObservationHandler(
        main_observation_type="text",
        text_observation_type="webrl",
        image_observation_type="",  # 原仓库在 webrl 下就是这个值
        current_viewport_only=True,
        viewport_size=viewport,
    )
    check(
        isinstance(handler.text_processor, __import__(
            "browser_env.processors", fromlist=["TextObervationProcessorWebRL"]
        ).TextObervationProcessorWebRL),
        "文本处理器仍是 TextObervationProcessorWebRL（简化 HTML）",
    )
    check(
        handler.image_processor.observation_type == "image",
        "图像处理器被改成 'image'",
        f"实际={handler.image_processor.observation_type!r}",
    )
    check(
        handler.main_observation_type == "text",
        "main_observation_type 仍为 text（动作仍走我们有图前的协议）",
    )

    # 非 webrl 的观测类型不应被我们改动
    other = ObservationHandler(
        main_observation_type="image",
        text_observation_type="image_som",
        image_observation_type="image_som",
        current_viewport_only=True,
        viewport_size=viewport,
    )
    check(
        other.image_processor.observation_type == "image_som",
        "非 webrl 组合（image_som）不受补丁影响",
    )


def test_agent_flag() -> None:
    print("\n[2] PromptAgent.multimodal_inputs")
    import agent.agent as agent_module
    from multimodal_eval.mm_prompt_constructor import (
        MultimodalWebRLPromptConstructor,
    )

    check(
        getattr(agent_module, "MultimodalWebRLPromptConstructor", None)
        is MultimodalWebRLPromptConstructor,
        "类名已注册到 agent.agent（construct_agent 的 eval() 才能找到）",
    )

    ctor = MultimodalWebRLPromptConstructor(TEMPLATE, make_lm_config(), None)
    agent = agent_module.PromptAgent(
        action_set_tag="webrl_id",
        lm_config=make_lm_config(),
        prompt_constructor=ctor,
        captioning_fn=None,
        planner_ip="http://localhost:8000/v1",
    )
    check(agent.multimodal_inputs is True, "multimodal_inputs=True（截图会被送进 prompt）")

    # 反向验证：补丁不能泄漏到原版构造器上，否则纯文本基线就跑不"纯"了
    from agent.prompts.prompt_constructor import WebRLChatPromptConstructor

    baseline = agent_module.PromptAgent(
        action_set_tag="webrl_id",
        lm_config=make_lm_config(),
        prompt_constructor=WebRLChatPromptConstructor(TEMPLATE, make_lm_config(), None),
        captioning_fn=None,
        planner_ip=None,
    )
    check(
        baseline.multimodal_inputs is False,
        "补丁不影响原版 WebRLChatPromptConstructor（纯文本基线仍走纯文本通道）",
    )


def inspect_messages(messages: list[dict]) -> dict:
    """统计消息结构，返回 {role, text_len, n_images} 列表。"""
    rows = []
    for msg in messages:
        content = msg.get("content")
        if isinstance(content, str):
            rows.append(
                {"role": msg.get("role"), "text_len": len(content), "n_images": 0}
            )
        else:
            text_len = sum(
                len(b.get("text", ""))
                for b in content or []
                if b.get("type") == "text"
            )
            n_img = sum(
                1 for b in content or [] if b.get("type") == "image_url"
            )
            rows.append({"role": msg.get("role"), "text_len": text_len, "n_images": n_img})
    return rows


def test_end_to_end_prompt() -> None:
    print("\n[3] 端到端：next_action 实际发出的 messages")
    import agent.agent as agent_module
    from multimodal_eval.mm_prompt_constructor import (
        MultimodalWebRLPromptConstructor,
    )

    captured: dict[str, Any] = {}

    def fake_call_llm(lm_config, prompt, api_key=None, base_url=None):
        captured["prompt"] = prompt
        captured["api_key"] = api_key
        captured["base_url"] = base_url
        return FAKE_REPLY

    agent_module.call_llm = fake_call_llm  # 只替换本地引用，不影响 llms 模块

    ctor = MultimodalWebRLPromptConstructor(TEMPLATE, make_lm_config(), None)
    agent = agent_module.PromptAgent(
        action_set_tag="webrl_id",
        lm_config=make_lm_config(),
        prompt_constructor=ctor,
        captioning_fn=None,
        planner_ip="http://localhost:8000/v1",
    )
    trajectory = make_trajectory(n_rounds=2)
    meta_data = {
        "action_history": [
            "None",
            FAKE_ACTION,
        ]
    }
    action = agent.next_action(
        trajectory, INTENT, meta_data, images=None, output_response=False
    )

    messages = captured.get("prompt")
    check(isinstance(messages, list) and len(messages) > 0, "拿到了 messages 列表")
    rows = inspect_messages(messages)
    print("      实际结构：")
    for i, row in enumerate(rows):
        print(
            f"        [{i}] role={row['role']:<9} text_len={row['text_len']:<6} "
            f"images={row['n_images']}"
        )

    check(
        sum(r["n_images"] for r in rows) == 1,
        "整段对话恰好带 1 张截图（默认只带当前轮）",
        f"实际={sum(r['n_images'] for r in rows)}",
    )
    last = messages[-1]
    check(last["role"] == "user", "最后一条是 user")
    content = last["content"]
    check(isinstance(content, list), "最后一条 user 的 content 是多模态列表")
    if isinstance(content, list):
        first_text = next(
            (b["text"] for b in content if b.get("type") == "text"), ""
        )
        check("Reports" in first_text, "HTML 文本原样保留在文本块里")
        # 原实现在 index>0 时只写 "Round N"（Task Instruction 只出现在 index==0），
        # 这里如实对齐，才能保证与纯文本基线逐字节可比
        check(
            "Round 1" in first_text and "Task Instruction" not in first_text,
            "当前轮前缀与原版一致（Round 1 开头，不含 Task Instruction）",
        )
        hist_user = [
            m for m in messages[:-1] if m.get("role") == "user"
        ]
        check(
            len(hist_user) == 1
            and "Task Instruction:" in hist_user[0]["content"]
            and "** Simplified html **" in hist_user[0]["content"],
            "历史轮的 HTML 被省略成占位符（原版行为保留）",
        )
        img_blocks = [b for b in content if b.get("type") == "image_url"]
        check(len(img_blocks) == 1, "恰好 1 个 image_url 块")
        if img_blocks:
            url = img_blocks[0]["image_url"]["url"]
            check(url.startswith("data:image/png;base64,"), "图像是 data URL 形式的 PNG")
            print(f"      图像 base64 长度 = {len(url)} 字符")
    check(
        captured.get("base_url") == "http://localhost:8000/v1",
        "base_url 走 planner_ip（你的 vLLM 网关）",
        str(captured.get("base_url")),
    )
    check(
        action.get("action_type") is not None and action.get("raw_prediction"),
        "动作解析正常（webrl_id）",
        f"action_type={action.get('action_type')}",
    )


def test_text_only_fallback() -> None:
    print("\n[4] 退化路径：没有截图时不崩")
    from multimodal_eval.mm_prompt_constructor import (
        MultimodalWebRLPromptConstructor,
    )

    ctor = MultimodalWebRLPromptConstructor(TEMPLATE, make_lm_config(), None)
    messages = ctor.construct(
        make_trajectory(n_rounds=2),
        INTENT,
        page_screenshot_img=None,
        images=None,
        meta_data={"action_history": ["None", "do(...)"]},
    )
    last = messages[-1]
    check(
        isinstance(last["content"], str),
        "无截图时 content 退回字符串（纯文本行为）",
    )


def test_history_images() -> None:
    print("\n[5] 可选：MM_HISTORY_IMAGES=1 时历史轮也带图")
    import importlib

    os.environ["MM_HISTORY_IMAGES"] = "1"
    mmc = importlib.import_module("multimodal_eval.mm_prompt_constructor")
    importlib.reload(mmc)
    ctor = mmc.MultimodalWebRLPromptConstructor(TEMPLATE, make_lm_config(), None)
    trajectory = make_trajectory(n_rounds=3)
    messages = ctor.construct(
        trajectory,
        INTENT,
        page_screenshot_img=make_image(99),
        images=None,
        meta_data={
            "action_history": ["None", "do(a)", "do(b)"],
        },
    )
    rows = inspect_messages(messages)
    for i, row in enumerate(rows):
        print(
            f"        [{i}] role={row['role']:<9} text_len={row['text_len']:<6} "
            f"images={row['n_images']}"
        )
    check(
        sum(r["n_images"] for r in rows) > 1,
        "历史轮被补上了当时的截图",
        f"总图数={sum(r['n_images'] for r in rows)}",
    )
    os.environ["MM_HISTORY_IMAGES"] = "0"


def main() -> int:
    print("=" * 72)
    print("多模态评测冒烟测试（无需浏览器 / 无需模型端点）")
    print(f"模板: {TEMPLATE}")
    print("=" * 72)

    from multimodal_eval.mm_patches import apply_patches

    apply_patches(verbose=False)
    print("  补丁已应用")

    test_observation_handler_patch()
    test_agent_flag()
    test_end_to_end_prompt()
    test_text_only_fallback()
    test_history_images()

    print("\n" + "=" * 72)
    if FAILURES:
        print(f"失败 {len(FAILURES)} 项：")
        for item in FAILURES:
            print(f"  - {item}")
        return 1
    print("全部通过。可以放心跑真实评测了：")
    print("  bash multimodal_eval/evaluate_shopping_admin_multimodal.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
