#!/usr/bin/env python3
"""WebArena 子集评测计分。

为什么不直接用 score.py:
  Eval/score.py 里 `TASKS = 165` 是写死的，而且最后的分站点汇总会去读
  config_files/wa/test_webarena_lite.raw.json（全量 165 条），没跑的任务按 0 算。
  所以只跑 35 条 shopping_admin 任务时，它算出的 overall accuracy 会被 165 除，
  分站点统计也会被稀释 —— 数字全错。

这个脚本按"你实际跑的那个任务目录"来统计，口径才对。

用法:
  python scripts/score_subset.py --result_dir eval_results/xxx \\
      --task_dir config_files/wa/test_webarena_lite_shopping_admin

  # 只看失败的任务
  python scripts/score_subset.py --result_dir eval_results/xxx \\
      --task_dir config_files/wa/test_webarena_lite_shopping_admin --show-failed
"""

import argparse
import glob
import json
import os
import sys


def main() -> int:
    p = argparse.ArgumentParser(description="按任务子集统计 WebArena 成功率")
    p.add_argument("--result_dir", required=True, help="run.py 的 --result_dir")
    p.add_argument("--task_dir", required=True, help="本次评测用的任务目录（如 config_files/wa/test_webarena_lite_shopping_admin）")
    p.add_argument("--show-failed", action="store_true", help="列出失败任务的 task_id 和 intent 摘要")
    args = p.parse_args()

    if not os.path.isdir(args.task_dir):
        print(f"[error] 任务目录不存在: {args.task_dir}", file=sys.stderr)
        return 1

    # 目标任务：内部 task_id -> 元信息
    targets: dict[int, dict] = {}
    for f in glob.glob(os.path.join(args.task_dir, "*.json")):
        with open(f, encoding="utf-8") as fp:
            t = json.load(fp)
        targets[t["task_id"]] = t

    if not targets:
        print(f"[error] {args.task_dir} 里没有任务", file=sys.stderr)
        return 1

    # 结果：actions/<task_id>.json，score<0 表示还没跑完/出错
    actions_dir = os.path.join(args.result_dir, "actions")
    scores: dict[int, float] = {}
    if os.path.isdir(actions_dir):
        for f in glob.glob(os.path.join(actions_dir, "*.json")):
            try:
                with open(f, encoding="utf-8") as fp:
                    jd = json.load(fp)
            except Exception:
                continue
            tid = jd.get("task_id")
            if isinstance(tid, int) and tid in targets:
                # 同一任务重跑时取最好成绩
                s = jd.get("score", -1)
                scores[tid] = max(scores.get(tid, -1), s)

    finished = {k: v for k, v in scores.items() if v is not None and v >= 0}
    success = [k for k, v in finished.items() if v >= 1.0]
    failed = [k for k, v in finished.items() if v < 1.0]
    not_run = sorted(set(targets) - set(finished))

    total = len(targets)

    print(f"任务目录 : {args.task_dir}")
    print(f"结果目录 : {args.result_dir}")
    print(f"任务总数 : {total}")
    print(f"已完成   : {len(finished)}")
    print(f"成功     : {len(success)}")
    print(f"失败     : {len(failed)}")
    print(f"未跑     : {len(not_run)}")
    print()
    if finished:
        print(f"完成任务的准确率 : {len(success) / len(finished) * 100:.2f}%  "
              f"({len(success)}/{len(finished)})")
        print(f"目标任务的准确率 : {len(success) / total * 100:.2f}%  "
              f"({len(success)}/{total})")
    else:
        print("还没有完成任何任务。")
        return 1
    print()
    print(f"成功的 task_id : {sorted(success)}")

    if args.show_failed and failed:
        print()
        print("失败明细:")
        for tid in sorted(failed):
            intent = targets[tid].get("intent", "")
            print(f"  [{tid:>4}] {intent[:90]}")

    if not_run:
        print()
        print(f"未跑的 task_id : {not_run}")
        print("  续跑: bash evaluate_shopping_admin.sh（脚本会自动只跑未完成的任务）")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
