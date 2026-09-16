#!/usr/bin/env python
"""多模态评测入口 —— 等价于 `python run.py ...`，但注入运行时补丁。

用法（**必须在 Eval/ 目录下运行**，因为 run.py 里全是相对路径）：

    cd WebAgent-R1/Eval
    MM_MULTIMODAL=1 python multimodal_eval/run_multimodal.py --help-like 参数

通常不用手敲，直接用配套的
    bash multimodal_eval/evaluate_shopping_admin_multimodal.sh

与 run.py 的关系
----------------
本文件**不修改** run.py，而是：先给库打补丁（见 mm_patches.py 的说明），
再用 runpy 以 `__name__ == "__main__"` 执行原封不动的 run.py。
因此 run.py 的所有行为（自动登录、早停、渲染、trace、计分）都原样保留。
"""

from __future__ import annotations

import os
import runpy
import sys
from pathlib import Path

EVAL_DIR = Path(__file__).resolve().parent.parent
MM_DIR = Path(__file__).resolve().parent

DEFAULT_INSTRUCTION = MM_DIR / "prompts" / "p_multimodal_webrl_chat_think.json"
DEFAULT_TASK_DIR = MM_DIR / "configs" / "shopping_admin"
DEFAULT_RESULT_DIR = MM_DIR / "results" / "shopping_admin_multimodal"
DEFAULT_PLANNER_IP = os.environ.get(
    "MM_PLANNER_IP",
    "https://inference.cluster.aimodelnetwork.cn/QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4/v1",
)
DEFAULT_MODEL = os.environ.get("MM_MODEL", "QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4")


# --------------------------------------------------------------------- argv
def _flag_index(argv: list[str], name: str) -> int | None:
    for i, item in enumerate(argv):
        if item == name or item.startswith(name + "="):
            return i
    return None


def get_flag(argv: list[str], name: str) -> str | None:
    i = _flag_index(argv, name)
    if i is None:
        return None
    item = argv[i]
    if "=" in item:
        return item.split("=", 1)[1]
    if i + 1 < len(argv):
        return argv[i + 1]
    return ""


def set_default(argv: list[str], name: str, value: str) -> bool:
    """参数缺失时补上默认值；已存在则原样保留。返回是否补了。"""
    if _flag_index(argv, name) is not None:
        return False
    argv += [name, str(value)]
    return True


# ------------------------------------------------------------------ 准备工作
def prepare_environment() -> None:
    """补上 run.py / 判分函数在 import 阶段就会读的环境变量。"""
    os.environ.setdefault("DATASET", "webarena")
    # openai_utils.py:18 在 import 阶段读 OPENAI_API_KEY，缺了直接 KeyError
    os.environ.setdefault("OPENAI_API_KEY", "EMPTY")
    # 判分（LLM-as-judge）走 OPENAI_API_URL，跟 planner_ip 是两套配置
    os.environ.setdefault("OPENAI_API_URL", DEFAULT_PLANNER_IP)
    os.environ.setdefault("JUDGE_MODEL", DEFAULT_MODEL)
    os.environ.setdefault("JUDGE_MAX_TOKENS", "2048")
    os.environ["TOKENIZERS_PARALLELISM"] = "false"


def check_protocol(argv: list[str]) -> None:
    """锁死观测/动作协议。

    只有 `webrl` + `webrl_id` 这一组能同时满足：
      - 文本观测是简化 HTML（`TextObervationProcessorWebRL`）
      - `env.step` 走 `execute_action_webrl`（envs.py:283）
      - 动作解析走 `create_webrl_id_based_action`
      - run.py:517 会写 traces/{task_id}.jsonl
    换成别的组合，补丁就失去意义了，所以这里直接拦住。
    """
    obs = get_flag(argv, "--observation_type")
    tag = get_flag(argv, "--action_set_tag")
    if obs != "webrl":
        sys.exit(
            f"[mm] 错误：--observation_type 必须是 webrl（当前: {obs!r}）。\n"
            "     多模态补丁只额外打开截图，不改观测/动作协议；改成 image_som 等\n"
            "     会让动作空间与 webrl_id 不兼容。"
        )
    if tag != "webrl_id":
        sys.exit(
            f"[mm] 错误：--action_set_tag 必须是 webrl_id（当前: {tag!r}）。"
        )


def check_instruction(argv: list[str]) -> None:
    """确认 prompt 模板指向我们的多模态构造器。"""
    import json

    path = get_flag(argv, "--instruction_path")
    if not path:
        return
    try:
        with open(path, encoding="utf-8") as f:
            meta = json.load(f)["meta_data"]
    except Exception as exc:
        sys.exit(f"[mm] 错误：无法读取 prompt 模板 {path}: {exc}")
    ctor = meta.get("prompt_constructor")
    if ctor != "MultimodalWebRLPromptConstructor":
        sys.exit(
            f"[mm] 错误：{path} 的 meta_data.prompt_constructor = {ctor!r}，\n"
            "     必须是 'MultimodalWebRLPromptConstructor'，否则截图不会被送进模型。"
        )


# ------------------------------------------------------------------ main
def main() -> None:
    os.chdir(EVAL_DIR)
    if str(EVAL_DIR) not in sys.path:
        sys.path.insert(0, str(EVAL_DIR))

    argv = sys.argv[1:]

    if "--help" in argv or "-h" in argv:
        print(__doc__)
        print("提示：`--help` 由本入口截获，不会透传给 run.py。")
        print("要看 run.py 的完整参数，请运行：python run.py --help")
        return

    prepare_environment()

    filled = []
    if set_default(argv, "--instruction_path", DEFAULT_INSTRUCTION):
        filled.append(f"--instruction_path={DEFAULT_INSTRUCTION}")
    if set_default(argv, "--observation_type", "webrl"):
        filled.append("--observation_type=webrl")
    if set_default(argv, "--action_set_tag", "webrl_id"):
        filled.append("--action_set_tag=webrl_id")
    if set_default(argv, "--provider", "openai"):
        filled.append("--provider=openai")
    if set_default(argv, "--mode", "chat"):
        filled.append("--mode=chat")
    if set_default(argv, "--model", DEFAULT_MODEL):
        filled.append(f"--model={DEFAULT_MODEL}")
    if set_default(argv, "--planner_ip", DEFAULT_PLANNER_IP):
        filled.append("--planner_ip=<默认网关>")
    if set_default(argv, "--test_config_base_dir", DEFAULT_TASK_DIR):
        filled.append(f"--test_config_base_dir={DEFAULT_TASK_DIR}")
    if set_default(argv, "--result_dir", DEFAULT_RESULT_DIR):
        filled.append(f"--result_dir={DEFAULT_RESULT_DIR}")
    if set_default(argv, "--stop_token", "<|im_end|>"):
        filled.append("--stop_token=<|im_end|>")

    check_protocol(argv)
    check_instruction(argv)

    # 补丁必须在 run.py import 之前打
    from multimodal_eval.mm_patches import MM_IMAGE_OBS, MM_TEXT_OBS, apply_patches

    try:
        apply_patches(verbose=True)
    except RuntimeError as exc:  # MM_MULTIMODAL 没开
        sys.exit(f"[mm] 错误: {exc}\n     （正确的调用方式见本文件开头，或直接用 "
                 "multimodal_eval/evaluate_shopping_admin_multimodal.sh）")
    if filled:
        print("[mm] 自动补全的参数：")
        for item in filled:
            print(f"[mm]   {item}")
    print(
        f"[mm] 文本观测={MM_TEXT_OBS}  图像观测={MM_IMAGE_OBS}  "
        f"模型={get_flag(argv, '--model')}  端点={get_flag(argv, '--planner_ip')}"
    )

    sys.argv = ["run.py"] + argv
    if os.environ.get("MM_DRY_RUN", "0") == "1":
        print("[mm] MM_DRY_RUN=1：到此为止，不执行 run.py。将要执行的等价命令：")
        print("     python run.py " + " ".join(argv))
        return
    runpy.run_path(str(EVAL_DIR / "run.py"), run_name="__main__")


if __name__ == "__main__":
    main()
