"""运行时补丁：在不改动 Eval/ 下任何原文件的前提下，打开「HTML 文本 + 截图」双通道。

为什么只需要三处补丁
--------------------
原仓库其实**已经**具备每一环能力，只是没被同时打开：

| 环节 | 现有实现 | 我们需要的 |
|---|---|---|
| 文本观测 | `TextObervationProcessorWebRL`（简化 HTML） | 原样保留 |
| 图像观测 | `ImageObservationProcessor` 每步都截图，但 `observation_type=webrl` 时
  `envs.py:110` 把 `image_observation_type` 置成 `""` | 改成 `"image"` |
| 观测组装 | `ObservationHandler.get_observation` 无条件同时跑文本+图像处理器 | 原样保留 |
| 图像入 prompt | `PromptAgent.__init__:124` 的判定只认 gemini / gpt-4-vision / provider∈{api,finetune} | 放行我们的构造器 |

所以补丁是：
  ① `browser_env.processors.ObservationHandler.__init__`：把 `image_observation_type`
     从 `""` 改成 `"image"`（**只影响处理器构造，不改 env 自身属性**）。
     `"image"`（而非 `"image_som"`）很关键：`ImageObservationProcessor.process` 在
     `image_som` 下会返回 SoM 说明文本，而 `get_observation` 里
     `if content_str != "": text_obs = content_str` 会把我们的 HTML 覆盖掉。
  ② `agent.agent.PromptAgent.__init__`：我们的构造器命中 `MultimodalCoTPromptConstructor`
     的 `type(...) ==` 精确类型判断失败，所以补丁里直接置 `multimodal_inputs = True`。
  ③ 注册类名：`construct_agent` 用 `eval(constructor_type)` 在 `agent.agent` 的模块
     命名空间里查类名，所以必须把我们的类注入那个命名空间。

不补丁、也不会被影响的东西：`env.step` 仍走 `execute_action_webrl`
（因为 `env.text_observation_type` 仍是 `"webrl"`），动作空间仍是 `webrl_id`，
`traces/{task_id}.jsonl` 仍会写。也就是说**唯一的变化就是模型多看到一张截图**。
"""

from __future__ import annotations

import json
import os
from pathlib import Path

# ---------------------------------------------------------------- 开关与常量
MM_ENABLED = os.environ.get("MM_MULTIMODAL", "0") == "1"
MM_TEXT_OBS = os.environ.get("MM_TEXT_OBS", "webrl")
MM_IMAGE_OBS = os.environ.get("MM_IMAGE_OBS", "image")
MM_DUMP_PROMPT = os.environ.get("MM_DUMP_PROMPT", "0") == "1"
MM_DUMP_DIR = Path(__file__).resolve().parent / "debug"

_applied: list[str] = []


# ------------------------------------------------------------------- 补丁 ①
def _patch_observation_handler() -> None:
    from browser_env.processors import ObservationHandler

    if getattr(ObservationHandler.__init__, "_mm_patched", False):
        return
    original = ObservationHandler.__init__

    def mm_init(
        self,
        main_observation_type: str,
        text_observation_type: str,
        image_observation_type: str,
        *args,
        **kwargs,
    ):
        if MM_ENABLED and text_observation_type == MM_TEXT_OBS:
            # 只有在我们明确要 "webrl 文本 + 截图" 时才动它；
            # 其它观测类型（image_som / accessibility_tree_with_captioner 等）保持原样。
            image_observation_type = MM_IMAGE_OBS
        original(
            self,
            main_observation_type,
            text_observation_type,
            image_observation_type,
            *args,
            **kwargs,
        )

    mm_init._mm_patched = True  # type: ignore[attr-defined]
    ObservationHandler.__init__ = mm_init
    _applied.append(
        f"ObservationHandler.__init__ -> image_observation_type={MM_IMAGE_OBS!r}"
    )


# ------------------------------------------------------------------- 补丁 ②③
def _patch_agent() -> None:
    import agent.agent as agent_module
    from multimodal_eval.mm_prompt_constructor import MultimodalWebRLPromptConstructor

    # ③ 注册类名，供 construct_agent 里的 eval(constructor_type) 解析
    agent_module.MultimodalWebRLPromptConstructor = MultimodalWebRLPromptConstructor
    try:  # 顺带注入 agent.prompts 命名空间，方便别处 from agent.prompts import *
        import agent.prompts as prompts_module

        prompts_module.MultimodalWebRLPromptConstructor = MultimodalWebRLPromptConstructor
    except Exception:  # pragma: no cover
        pass
    _applied.append(
        "agent.agent.MultimodalWebRLPromptConstructor 已注册（供 eval() 解析）"
    )

    cls = agent_module.PromptAgent
    if not getattr(cls.__init__, "_mm_patched", False):
        original_init = cls.__init__

        def mm_init(self, *args, **kwargs):
            original_init(self, *args, **kwargs)
            pc = getattr(self, "prompt_constructor", None)
            if isinstance(pc, MultimodalWebRLPromptConstructor):
                # 绕过 agent.py:124 那个只认 gemini / gpt-4-vision / api / finetune
                # 的判定 —— 我们的端点（vLLM 上的 Qwen3.8-27B）同样能收图像。
                self.multimodal_inputs = True

        mm_init._mm_patched = True  # type: ignore[attr-defined]
        cls.__init__ = mm_init
    _applied.append("PromptAgent.__init__ -> multimodal_inputs=True（仅对本构造器）")


# ------------------------------------------------------------------- 可选：取样
def _install_prompt_dumper() -> None:
    """MM_DUMP_PROMPT=1 时，把每个进程第一次真正发出的多模态 prompt 落盘。

    落盘内容刻意不含完整 base64（会非常长）：
      - `mm_prompt_sample_*.json`：消息结构 + 文本长度 + 图像 base64 长度
      - `mm_prompt_sample_*.png`：那张被送进去的截图本身
    想看「模型到底收到什么」，看这两个文件最快，不必去翻 traces。
    """
    from multimodal_eval.mm_prompt_constructor import MultimodalWebRLPromptConstructor

    if getattr(MultimodalWebRLPromptConstructor.construct, "_mm_dumped", False):
        return
    original = MultimodalWebRLPromptConstructor.construct

    def dumping_construct(
        self, trajectory, intent, page_screenshot_img=None, images=None, meta_data={}
    ):
        messages = original(
            self, trajectory, intent, page_screenshot_img, images, meta_data
        )
        if not getattr(self, "_mm_dumped_once", False):
            self._mm_dumped_once = True  # type: ignore[attr-defined]
            try:
                MM_DUMP_DIR.mkdir(parents=True, exist_ok=True)
                tag = f"{os.getpid()}_{len(list(MM_DUMP_DIR.glob('*.json')))}"
                summary = []
                for msg in messages:
                    content = msg.get("content")
                    if isinstance(content, str):
                        summary.append(
                            {"role": msg.get("role"), "text_len": len(content)}
                        )
                    else:
                        blocks = []
                        for block in content or []:
                            if block.get("type") == "text":
                                blocks.append(
                                    {"type": "text", "len": len(block.get("text", ""))}
                                )
                            elif block.get("type") == "image_url":
                                url = block["image_url"]["url"]
                                blocks.append(
                                    {
                                        "type": "image_url",
                                        "url_prefix": url[:30],
                                        "b64_len": len(url),
                                    }
                                )
                        summary.append({"role": msg.get("role"), "blocks": blocks})
                (MM_DUMP_DIR / f"mm_prompt_sample_{tag}.json").write_text(
                    json.dumps(
                        {
                            "intent": intent,
                            "n_messages": len(messages),
                            "n_images": getattr(self, "n_images_sent", 0),
                            "messages": summary,
                        },
                        ensure_ascii=False,
                        indent=2,
                    ),
                    encoding="utf-8",
                )
                if page_screenshot_img is not None:
                    page_screenshot_img.save(
                        MM_DUMP_DIR / f"mm_prompt_sample_{tag}.png"
                    )
                print(
                    f"[mm] 已把本轮多模态 prompt 样本写入 {MM_DUMP_DIR}/"
                    f"mm_prompt_sample_{tag}.json（含配套 png）"
                )
            except Exception as exc:
                print(f"[mm] WARNING: prompt 取样失败: {exc}")
        return messages

    dumping_construct._mm_dumped = True  # type: ignore[attr-defined]
    MultimodalWebRLPromptConstructor.construct = dumping_construct
    _applied.append(f"已开启 prompt 取样（输出到 {MM_DUMP_DIR}）")


# ---------------------------------------------------------------------- 入口
def apply_patches(verbose: bool = True) -> None:
    if not MM_ENABLED:
        raise RuntimeError(
            "MM_MULTIMODAL 未设为 1。这是多模态评测的显式开关，"
            "防止误把带图请求打到不支持图像的模型上。"
        )
    _patch_observation_handler()
    _patch_agent()
    if MM_DUMP_PROMPT:
        _install_prompt_dumper()
    if verbose:
        print("[mm] 已应用运行时补丁：")
        for line in _applied:
            print(f"[mm]   - {line}")
        print(
            "[mm] 结论：文本观测仍为 WebRL 简化 HTML，动作空间仍为 webrl_id，"
            "额外差异仅为模型可见一张页面截图。"
        )


def applied_patches() -> list[str]:
    return list(_applied)
