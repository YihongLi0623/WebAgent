"""多模态 prompt 构造器：把「简化 HTML 文本」和「当前页截图」一起送给模型。

设计要点
--------
1. **继承**原仓库的 `WebRLChatPromptConstructor`，不复制它的实现。
   这样文本部分（system intro、历史轮的 `** Simplified html **` 省略、
   `Task Instruction:` 前缀、`Round N` 编号）与原版**逐字节一致**，
   加了截图之后的效果才和纯文本基线可比。
2. 只做一件事：把最后一条 `user` 消息的字符串 content 换成 OpenAI 多模态
   格式的 content 列表，并在文本之后追加 `image_url`。
3. 可选地把历史轮当时的截图也补上（`MM_HISTORY_IMAGES=1`），
   因为历史轮的 HTML 被原实现省略成了占位符，补图反而更有信息量。

环境变量
--------
MM_IMAGE_NOTE      截图前的文字提示，默认 "** Screenshot of current page **"
MM_IMAGE_FIRST     1 = 把截图放在 HTML 文本**之前**（贴近原 SoM 协议的顺序）
MM_HISTORY_IMAGES  1 = 历史轮也带各自当时的截图（显著增加 token / 图像数）
MM_MAX_IMAGE_SIDE  缩放上限（长边像素），0 = 不缩放（默认，保持 1280x720 原样）
"""

from __future__ import annotations

import os
from typing import Any, Optional

from PIL import Image

from agent.prompts.prompt_constructor import WebRLChatPromptConstructor
from browser_env.utils import pil_to_b64

__all__ = ["MultimodalWebRLPromptConstructor"]


def _resampling_lanczos():
    """兼容新旧 Pillow：Image.LANCZOS 在 Pillow>=9.1 被挪到 Image.Resampling。"""
    resampling = getattr(Image, "Resampling", None)
    if resampling is not None:
        return resampling.LANCZOS
    return Image.LANCZOS


class MultimodalWebRLPromptConstructor(WebRLChatPromptConstructor):
    """在 WebRL 文本 prompt 的基础上，把页面截图一并作为图像输入。"""

    def __init__(
        self,
        instruction_path,
        lm_config,
        tokenizer,
    ) -> None:
        super().__init__(instruction_path, lm_config, tokenizer)
        self.image_note = os.environ.get(
            "MM_IMAGE_NOTE", "** Screenshot of current page **"
        )
        self.image_first = os.environ.get("MM_IMAGE_FIRST", "0") == "1"
        self.history_images = os.environ.get("MM_HISTORY_IMAGES", "0") == "1"
        self.max_image_side = int(os.environ.get("MM_MAX_IMAGE_SIDE", "0") or 0)
        # 统计用，便于在日志里确认「图真的送进去了」
        self.n_images_sent = 0

    # ------------------------------------------------------------------ utils
    @staticmethod
    def _as_pil(img):
        """统一成 PIL.Image。

        **这是踩过的坑**：当前轮的截图由 `PromptAgent.next_action` 传进来，是
        `Image.fromarray(...)` 得到的 PIL 对象；但历史轮的截图只能从
        `trajectory[i]["observation"]["image"]` 取，那是
        `ImageObservationProcessor.process` 产出的 **numpy 数组**。
        不转换的话 `pil_to_b64` 会抛 `'numpy.ndarray' object has no attribute 'save'`，
        而我们的兜底又会把它降级成纯文本 —— 表现为"开了 MM_HISTORY_IMAGES 但一张图都没有"，
        很难查。所以这里显式处理两种类型。
        """
        if img is None or isinstance(img, Image.Image):
            return img
        try:
            return Image.fromarray(img)
        except Exception as exc:
            print(f"[mm] WARNING: 无法把 {type(img).__name__} 转成 PIL 图: {exc}")
            return None

    def _image_part(self, img) -> Optional[dict]:
        """把 PIL 图（或 numpy 数组）转成 OpenAI chat 的 image_url content 块。"""
        img = self._as_pil(img)
        if img is None:
            return None
        try:
            if self.max_image_side and max(img.size) > self.max_image_side:
                ratio = self.max_image_side / float(max(img.size))
                new_size = (
                    max(1, int(img.size[0] * ratio)),
                    max(1, int(img.size[1] * ratio)),
                )
                img = img.resize(new_size, _resampling_lanczos())
            return {"type": "image_url", "image_url": {"url": pil_to_b64(img)}}
        except Exception as exc:  # 图像坏掉不应该让整个任务挂掉
            print(f"[mm] WARNING: 截图编码失败，本轮退化为纯文本: {exc}")
            return None

    def _trajectory_image(self, trajectory, round_idx: int):
        """取第 round_idx 轮（0-based）观测时的截图。

        轨迹结构：[state_info(round 0), action(0), state_info(round 1), action(1), ...]
        所以第 i 轮的 state_info 在 trajectory[2*i]。
        """
        pos = 2 * round_idx
        if pos >= len(trajectory):
            return None
        state = trajectory[pos]
        if not isinstance(state, dict):
            return None
        obs = state.get("observation") or {}
        return obs.get("image")

    @staticmethod
    def _to_text_content(message: dict) -> str:
        """把 content 列表（可能是上一轮改造过的）还原成纯文本。"""
        content = message.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    return block.get("text", "")
        return ""

    def _attach_image(self, message: dict, img) -> bool:
        """把一条消息的 content 从字符串升级为 [text, image] 列表。"""
        part = self._image_part(img)
        if part is None:
            return False
        text = self._to_text_content(message)
        content = []
        if not self.image_first:
            content.append({"type": "text", "text": text})
        content.append({"type": "text", "text": self.image_note})
        content.append(part)
        if self.image_first:
            content.append({"type": "text", "text": text})
        message["content"] = content
        self.n_images_sent += 1
        return True

    # -------------------------------------------------------------- interface
    def construct(
        self,
        trajectory,
        intent: str,
        page_screenshot_img: Optional[Image.Image] = None,
        images: Optional[list[Image.Image]] = None,
        meta_data: dict[str, Any] = {},
    ):
        """先按原版拼出文本会话，再注入图像。

        注意：调用签名必须与 `MultimodalCoTPromptConstructor.construct` 一致，
        因为 PromptAgent 在 multimodal_inputs=True 时是按位置传参的。
        """
        messages = super().construct(trajectory, intent, meta_data)

        # 1) 当前轮截图 —— 挂在最后一条 user 消息上
        if page_screenshot_img is not None:
            self._attach_image(messages[-1], page_screenshot_img)

        # 2) 任务自带的输入图（shopping_admin 任务里没有，保留以兼容 visualwebarena）
        if images:
            tail = messages[-1]
            content = tail.get("content")
            if isinstance(content, str):
                # 上面没挂上图，这里要先升级成列表
                content = [{"type": "text", "text": content}]
            if isinstance(content, list):
                for idx, img in enumerate(images):
                    part = self._image_part(img)
                    if part is None:
                        continue
                    content.append(
                        {"type": "text", "text": f"({idx + 2}) input image {idx + 1}"}
                    )
                    content.append(part)
                    self.n_images_sent += 1
                tail["content"] = content

        # 3) 历史轮补图（可选）
        if self.history_images:
            for round_idx in range(len(messages) // 2):
                pos = 1 + 2 * round_idx
                if pos >= len(messages) - 1:  # 最后一条是当前轮的 user，跳过
                    break
                msg = messages[pos]
                if msg.get("role") != "user":
                    continue
                img = self._trajectory_image(trajectory, round_idx)
                if img is not None:
                    self._attach_image(msg, img)

        return messages
