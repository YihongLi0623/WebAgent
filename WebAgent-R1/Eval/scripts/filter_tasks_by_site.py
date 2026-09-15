#!/usr/bin/env python3
"""按站点筛选 WebArena 任务，生成一个可以单独跑的连续编号任务目录。

背景（为什么需要这个脚本）:
  Eval/run.py 取任务的方式是硬编码的:
      for i in range(test_start_idx, test_end_idx):
          test_file_list.append(os.path.join(test_config_base_dir, f"{i}.json"))
  也就是说它只会去读 `0.json, 1.json, 2.json ...` 这种**连续编号**的文件。
  所以想"只跑 shopping_admin 的任务"不能靠 --test_start_idx/--test_end_idx 跳选，
  必须把目标任务挑出来、重新编号成 0..N-1，放到一个新目录里。

用法示例:
  # 只挑"纯 shopping_admin"任务（sites == ["shopping_admin"]）
  python scripts/filter_tasks_by_site.py --site shopping_admin

  # 挑"只要用到 shopping_admin 的任务"（含 map+shopping_admin 这种组合）
  python scripts/filter_tasks_by_site.py --site shopping_admin --mode any

  # 指定源目录/输出目录
  python scripts/filter_tasks_by_site.py \
      --src config_files/wa/test_webarena_lite \
      --dst config_files/wa/test_webarena_lite_shopping_admin \
      --site shopping_admin

生成后这样跑评测:
  python run.py ... --test_config_base_dir config_files/wa/test_webarena_lite_shopping_admin \
      --test_start_idx 0 --test_end_idx <N>
"""

import argparse
import json
import os
import shutil
import sys


def load_tasks(src: str) -> list[tuple[int, dict]]:
    """按文件名数字顺序读入全部任务，返回 [(原序号, task_dict), ...]"""
    items = []
    for name in os.listdir(src):
        if not name.endswith(".json"):
            continue
        stem = name[:-5]
        if not stem.isdigit():
            continue
        with open(os.path.join(src, name), encoding="utf-8") as f:
            items.append((int(stem), json.load(f)))
    items.sort(key=lambda x: x[0])
    return items


def rewrite_host(obj, host: str):
    """递归把字符串里的 http://localhost:<port> 换成 http://<host>:<port>。

    任务 JSON 的 start_url / reference_url 都是写死的 localhost，
    浏览器实际访问的地址必须以这个为准，否则 url_match 类评测会两边对不上。
    """
    if isinstance(obj, str):
        return obj.replace("http://localhost:", f"http://{host}:")
    if isinstance(obj, dict):
        return {k: rewrite_host(v, host) for k, v in obj.items()}
    if isinstance(obj, list):
        return [rewrite_host(v, host) for v in obj]
    return obj


def main() -> int:
    p = argparse.ArgumentParser(description="按站点筛选 WebArena 任务并重新编号")
    p.add_argument("--src", default="config_files/wa/test_webarena_lite",
                   help="源任务目录（默认 test_webarena_lite，165 条）")
    p.add_argument("--dst", default=None,
                   help="输出目录，默认 <src>_<site>")
    p.add_argument("--site", required=True,
                   help="站点名，如 shopping_admin / shopping / gitlab / reddit / map / wikipedia")
    p.add_argument("--mode", choices=["single", "any"], default="single",
                   help="single=只挑该站点的单站点任务；any=只要任务涉及该站点就挑（默认 single）")
    p.add_argument("--overwrite", action="store_true", help="输出目录已存在时覆盖")
    p.add_argument("--dry-run", action="store_true", help="只统计不写文件")
    p.add_argument("--limit", type=int, default=0,
                   help="只取前 N 个命中任务（0=全部），方便先小规模试跑")
    p.add_argument("--ids", type=str, default="",
                   help="只取指定 task_id，逗号分隔，如 --ids 0,2,8（与原 task_id 对应）")
    p.add_argument("--exclude-done", type=str, default="",
                   help="排除已在 <RESULT_DIR>/actions/*.json 中跑完（score>=0）的任务，"
                        "用于断点续跑。注意 run.py 自带的续跑判断用文件名序号，"
                        "对重新编号过的目录会失效，所以必须用这个参数")
    p.add_argument("--host", type=str, default="",
                   help="把任务里写死的 http://localhost:<port> 重写成 http://<host>:<port>。"
                        "任务 JSON 的 start_url / reference_url 都是 localhost，"
                        "只有在容器本机跑评测才不用改；--host localhost 等价于不重写")
    args = p.parse_args()

    if not os.path.isdir(args.src):
        print(f"[error] 源目录不存在: {args.src}", file=sys.stderr)
        return 1

    dst = args.dst or f"{args.src.rstrip('/')}_{args.site}"

    tasks = load_tasks(args.src)
    if not tasks:
        print(f"[error] {args.src} 里没找到 <数字>.json 任务文件", file=sys.stderr)
        return 1

    # 全量分布，方便对照
    dist: dict[tuple, int] = {}
    for _, t in tasks:
        key = tuple(sorted(t.get("sites", [])))
        dist[key] = dist.get(key, 0) + 1

    if args.mode == "single":
        picked = [(i, t) for i, t in tasks if sorted(t.get("sites", [])) == [args.site]]
    else:
        picked = [(i, t) for i, t in tasks if args.site in t.get("sites", [])]

    # --ids：按 JSON 内部 task_id 精确挑选
    if args.ids:
        want = {int(x) for x in args.ids.replace(" ", "").split(",") if x}
        picked = [(i, t) for i, t in picked if t.get("task_id") in want]
        missing = want - {t.get("task_id") for _, t in picked}
        if missing:
            print(f"[warn] 这些 task_id 不在命中集合中，已忽略: {sorted(missing)}", file=sys.stderr)

    # --exclude-done：排除已跑完的任务（按内部 task_id 查 actions/*.json）
    if args.exclude_done:
        actions_dir = os.path.join(args.exclude_done, "actions")
        done: set[int] = set()
        if os.path.isdir(actions_dir):
            for name in os.listdir(actions_dir):
                if not name.endswith(".json"):
                    continue
                try:
                    with open(os.path.join(actions_dir, name), encoding="utf-8") as f:
                        jd = json.load(f)
                except Exception:
                    continue
                tid = jd.get("task_id")
                if isinstance(tid, int) and jd.get("score", -1) >= 0:
                    done.add(tid)
        before = len(picked)
        picked = [(i, t) for i, t in picked if t.get("task_id") not in done]
        print(f"已跳过跑完的任务: {before - len(picked)} 个（剩余 {len(picked)} 个待跑）")

    if args.limit and len(picked) > args.limit:
        picked = picked[: args.limit]

    print(f"源目录 : {args.src}  (共 {len(tasks)} 个任务)")
    print(f"筛选   : site={args.site}  mode={args.mode}")
    print(f"命中   : {len(picked)} 个任务")
    if not picked:
        if args.exclude_done:
            print("\n全部任务都已跑完，无需再跑。")
            return 0
        print("\n可用站点分布：")
        for k, v in sorted(dist.items(), key=lambda x: -x[1]):
            print(f"   {v:4d}  {'+'.join(k)}")
        return 1

    if args.dry_run:
        print("\n--dry-run，未写文件。命中任务的原 task_id：")
        print("  ", [t.get("task_id") for _, t in picked])
        return 0

    if os.path.isdir(dst):
        if not args.overwrite:
            print(f"\n[error] 输出目录已存在: {dst}\n  加 --overwrite 覆盖，或用 --dst 指定别的目录",
                  file=sys.stderr)
            return 1
        shutil.rmtree(dst)
    os.makedirs(dst)

    # 关键：文件名重排成 0..N-1，但**保留 JSON 内部的原始 task_id**
    # （result_dir/actions/<task_id>.json、评分、breakdown 统计都依赖内部 task_id）
    need_rewrite = bool(args.host) and args.host != "localhost"
    for new_idx, (_, task) in enumerate(picked):
        if need_rewrite:
            task = rewrite_host(task, args.host)
        with open(os.path.join(dst, f"{new_idx}.json"), "w", encoding="utf-8") as f:
            json.dump(task, f, ensure_ascii=False, indent=2)

    # 顺带生成一个列表文件，和仓库里 config_files/wa/<name>.json 的约定保持一致
    # （scripts/calc_breakdown_sr.py --config_file 需要它）
    list_path = f"{dst.rstrip('/')}.json"
    listed = [rewrite_host(t, args.host) if need_rewrite else t for _, t in picked]
    with open(list_path, "w", encoding="utf-8") as f:
        json.dump(listed, f, ensure_ascii=False, indent=2)

    hosts = {}
    for _, t in picked:
        su = t.get("start_url") or ""
        host = su.split("/")[2] if "://" in su else "(none)"
        hosts[host] = hosts.get(host, 0) + 1

    print(f"\n已生成:")
    print(f"  任务目录 : {dst}   ({len(picked)} 个文件, 0.json .. {len(picked)-1}.json)")
    print(f"  列表文件 : {list_path}")
    print(f"  原始 task_id 已保留在 JSON 内（文件名仅用于排序）")
    print(f"\n任务访问的主机:")
    for h, c in sorted(hosts.items(), key=lambda x: -x[1]):
        print(f"  {c:4d}  {h}")
    print(f"\n下一步（评测）:")
    print(f"  python run.py <原有参数> \\")
    print(f"      --test_config_base_dir {dst} \\")
    print(f"      --test_start_idx 0 --test_end_idx {len(picked)}")
    print(f"\n统计成功率:")
    print(f"  python scripts/calc_breakdown_sr.py --config_file {list_path} "
          f"--log_file <你的日志>")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
