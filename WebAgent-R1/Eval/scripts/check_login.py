#!/usr/bin/env python3
"""验证 shopping_admin 的登录 cookie 是否真的有效。

为什么要单独验一下：
  run.py 每个任务会用 auto_login.py 重新登录一次（写入临时目录），但
  auto_login.py 走的是 `--site_list` 分支 —— 那条路**跳过 is_expired 校验**
  （只有不带参数走 main() 才校验）。所以"登录脚本跑完了"不等于"真登录上了"：
  表单选择器不匹配、base_url 配错、账号密码不对，都会安静地写出一个
  未认证的 cookie 文件。

  而这个项目里 35 个 shopping_admin 任务中有 14 个是 program_html / url_match，
  评测器会重新 page.goto() 后台页面取 DOM —— 没登录就会被重定向到登录页，
  locator 查不到元素 → 静默得 0 分。跑之前先验一下能省一小时。

用法:
  python scripts/check_login.py
  python scripts/check_login.py --state-file ./.auth/shopping_admin_state.json
  python scripts/check_login.py --url http://localhost:8083/admin/dashboard
"""

import argparse
import sys
import time
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser(description="验证 shopping_admin 登录 cookie 是否有效")
    p.add_argument("--state-file", default="./.auth/shopping_admin_state.json",
                   help="auto_login.py 产出的 storage_state 文件")
    p.add_argument("--url", default="",
                   help="要验证的后台页面，默认 <SHOPPING_ADMIN>/dashboard")
    p.add_argument("--keyword", default="Dashboard",
                   help="登录成功后该页面会出现的字，默认 Dashboard")
    p.add_argument("--timeout", type=int, default=60, help="页面加载超时（秒）")
    p.add_argument("--show", action="store_true", help="打印最终 URL 和页面片段，便于排查")
    args = p.parse_args()

    state = Path(args.state_file)
    if not state.exists():
        print(f"[FAIL] cookie 文件不存在: {state}")
        print("       先跑: python browser_env/auto_login.py --site_list shopping_admin --auth_folder ./.auth")
        return 1

    # 需要 SHOPPING_ADMIN 环境变量（browser_env.env_config 会在 import 时读）
    try:
        from browser_env.env_config import SHOPPING_ADMIN
    except Exception as e:
        print(f"[FAIL] 无法导入 env_config（DATASET / 各站点 URL 环境变量没设全）: {e}")
        return 1

    if not SHOPPING_ADMIN:
        print("[FAIL] SHOPPING_ADMIN 为空")
        return 1

    url = args.url or f"{SHOPPING_ADMIN.rstrip('/')}/dashboard"

    from playwright.sync_api import sync_playwright

    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=True)
            context = browser.new_context(storage_state=str(state))
            page = context.new_page()
            page.goto(url, timeout=args.timeout * 1000)
            time.sleep(2)
            final_url = page.url
            content = page.content()
            browser.close()
    except Exception as e:
        print(f"[FAIL] 打开 {url} 失败: {e}")
        return 1

    if args.show:
        print(f"  最终 URL   : {final_url}")
        print(f"  页面长度   : {len(content)}")
        print(f"  关键字命中 : {args.keyword in content}")

    # 未登录时 Magento 会把 /admin/dashboard 重定向回 /admin（登录页）
    logged_in = ("dashboard" in final_url) and (args.keyword in content)
    if logged_in:
        print(f"[OK] 登录有效（{url} -> {final_url}）")
        return 0

    print(f"[FAIL] 登录无效：{url} 最终停在 {final_url}")
    if args.keyword not in content:
        print(f"       页面里找不到关键字 '{args.keyword}'")
    print("       排查方向：")
    print("        1) SHOPPING_ADMIN 地址是否正确（要带 /admin）")
    print("        2) 容器 base-url 是否配成同一个地址（start_shopping_admin.sh 里的 PUBLIC_HOSTNAME / 端口）")
    print("        3) 账号密码（默认 admin / admin1234）")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
