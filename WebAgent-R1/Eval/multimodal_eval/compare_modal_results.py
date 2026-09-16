#!/usr/bin/env python
"""对比「纯文本」与「文本+截图」两次评测的逐条结果。

    python multimodal_eval/compare_modal_results.py \
        --text-dir eval_results/shopping_admin_qwen3.8-27b-quasar \
        --mm-dir   multimodal_eval/results/shopping_admin_multimodal \
        --task-dir multimodal_eval/configs/shopping_admin

只读 `actions/<task_id>.json`，不依赖 numpy/playwright，可直接在任意机器上跑。

判定口径
--------
- score >= 1 记 PASS；0 <= score < 1 记 FAIL；缺 score 字段或 score < 0 记 NOT_RUN
  （与 scripts/score_subset.py 一致：score = -1 是 run.py 写的"未完成"占位，-0.1 是初始值）
- 汇总里给出两组的 PASS 数、以及「文本 FAIL → 多模态 PASS」/「文本 PASS → 多模态 FAIL」
  两个翻转清单 —— 这是判断截图到底有没有帮上忙的最直接证据。
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def load_scores(result_dir: Path) -> dict[str, dict]:
    out: dict[str, dict] = {}
    actions_dir = result_dir / "actions"
    if not actions_dir.is_dir():
        return out
    for path in sorted(actions_dir.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        out[str(data.get("task_id", path.stem))] = data
    return out


def verdict(rec: dict | None) -> str:
    if not rec:
        return "NOT_RUN"
    score = rec.get("score")
    if score is None or score < 0:
        return "NOT_RUN"
    return "PASS" if score >= 1 else "FAIL"


def load_intents(task_dir: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not task_dir.is_dir():
        return out
    for path in sorted(task_dir.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        out[str(data.get("task_id"))] = data.get("intent", "")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--text-dir", required=True, help="纯文本基线的结果目录")
    parser.add_argument("--mm-dir", required=True, help="多模态实验的结果目录")
    parser.add_argument("--task-dir", default="", help="可选：任务目录，用于打印 intent")
    parser.add_argument("--show-intent", action="store_true", help="打印每条任务的 intent")
    parser.add_argument("--width", type=int, default=70, help="intent 截断宽度")
    args = parser.parse_args()

    text_dir, mm_dir = Path(args.text_dir), Path(args.mm_dir)
    text = load_scores(text_dir)
    mm = load_scores(mm_dir)
    intents = load_intents(Path(args.task_dir)) if args.task_dir else {}

    if not text:
        print(f"[warn] {text_dir}/actions/ 里没有结果文件")
    if not mm:
        print(f"[warn] {mm_dir}/actions/ 里没有结果文件")
    if not text and not mm:
        return 1

    task_ids = sorted(set(text) | set(mm), key=lambda x: (len(x), x))

    def num(recs: dict[str, dict], want: str) -> int:
        return sum(1 for tid in task_ids if verdict(recs.get(tid)) == want)

    def denom(recs: dict[str, dict]) -> int:
        return sum(1 for tid in task_ids if verdict(recs.get(tid)) != "NOT_RUN")

    print("=" * 96)
    print(f"{'task_id':>8}  {'text':^9}  {'multimodal':^11}  {'翻转':^6}  intent")
    print("-" * 96)
    gained, lost, both_pass, both_fail = [], [], [], []
    for tid in task_ids:
        v_text, v_mm = verdict(text.get(tid)), verdict(mm.get(tid))
        flip = ""
        if v_text == "FAIL" and v_mm == "PASS":
            flip, bucket = "^ 提升", gained
        elif v_text == "PASS" and v_mm == "FAIL":
            flip, bucket = "v 退化", lost
        elif v_text == "PASS" and v_mm == "PASS":
            bucket = both_pass
        elif v_text == "FAIL" and v_mm == "FAIL":
            bucket = both_fail
        else:
            bucket = None
        if bucket is not None:
            bucket.append(tid)
        line = f"{tid:>8}  {v_text:^9}  {v_mm:^11}  {flip:^6}"
        if args.show_intent:
            intent = intents.get(tid, "")
            if len(intent) > args.width:
                intent = intent[: args.width - 3] + "..."
            line += f"  {intent}"
        print(line)

    print("=" * 96)
    print(f"任务总数（两组并集）: {len(task_ids)}")
    for name, recs in (("纯文本  ", text), ("多模态  ", mm)):
        n_pass = num(recs, "PASS")
        n_run = denom(recs)
        rate = f"{n_pass / n_run * 100:.1f}%" if n_run else "n/a"
        print(
            f"{name}  PASS {n_pass:>3} / 已跑 {n_run:>3} = {rate:>6}"
            f"   （FAIL {num(recs, 'FAIL')}, 未跑 {len(task_ids) - n_run}）"
        )
    print()
    print(f"文本 FAIL → 多模态 PASS（截图有帮助）: {len(gained)} 条 {gained}")
    print(f"文本 PASS → 多模态 FAIL（截图有干扰）: {len(lost)} 条 {lost}")
    print(f"两边都 PASS: {len(both_pass)} 条")
    print(f"两边都 FAIL: {len(both_fail)} 条")
    print()
    print("注意：翻转数很小（个位数）时，差异可能落在随机性范围内 ——")
    print("      TEMPERATURE=1.0 下同一条任务重跑分数都可能变。要下结论建议固定 temperature 并重复 3 次。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
