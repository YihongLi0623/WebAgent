#!/usr/bin/env python
"""多模态端点预检 —— 确认模型真的能接收图像输入。

只依赖标准库（urllib），不引入任何新包。

    MM_PLANNER_IP=... MM_MODEL=... python multimodal_eval/check_vision_endpoint.py

为什么需要它：这次实验的**唯一**变量就是把截图喂给模型。如果端点其实拒收
`image_url`（vLLM 没带视觉塔 / 网关把 content 列表拍平），35 条任务会全崩，
而报错会散落在 `logs/chunk_*.log` 里很难一眼看出。所以跑批量前先打一发最小请求。
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

# 一张 1x1 的纯白 PNG
TINY_PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
)


def fail(msg: str) -> int:
    print(f"[vision-check] 失败: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    base = os.environ.get("MM_PLANNER_IP", "").rstrip("/")
    model = os.environ.get("MM_MODEL", "")
    if not base:
        return fail("MM_PLANNER_IP 未设置")
    url = f"{base}/chat/completions"
    print(f"[vision-check] POST {url}  (model={model})")

    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": "Reply with exactly one word: the dominant color of this image.",
                    },
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/png;base64,{TINY_PNG_B64}"},
                    },
                ],
            }
        ],
        "max_tokens": 64,
        "temperature": 0,
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {os.environ.get('OPENAI_API_KEY', 'EMPTY')}",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "ignore")[:400]
        return fail(f"HTTP {exc.code} —— {detail}\n  提示：确认 MM_PLANNER_IP 写到 /v1 为止，"
                    "且模型 id 是带命名空间的完整名")
    except Exception as exc:
        return fail(f"请求异常: {exc}")

    if "error" in body:
        return fail(f"服务端返回 error: {json.dumps(body['error'], ensure_ascii=False)[:400]}")

    try:
        choice = body["choices"][0]
        message = choice["message"]
    except Exception:
        return fail(f"返回结构异常: {json.dumps(body, ensure_ascii=False)[:400]}")

    content = message.get("content")
    reasoning = message.get("reasoning")
    print(f"[vision-check] finish_reason = {choice.get('finish_reason')}")
    print(f"[vision-check] content       = {content!r}")
    if reasoning:
        print(f"[vision-check] reasoning 长度 = {len(reasoning)}（思考模型会把思维链拆到这里）")

    if not content and not reasoning:
        return fail("模型既没返回 content 也没返回 reasoning —— 图像可能被网关丢弃")

    print("[vision-check] 端点接受图像输入 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
