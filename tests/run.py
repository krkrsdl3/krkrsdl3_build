#!/usr/bin/env python3
"""离屏静音跑 krkrsdl3，并把窗口内容/交互结果落成可查的 PNG 与 state.txt。

用法示例：
  python tests/run.py --game out/testgame/data.xp3 --harness tests/harness_boot.tjs
  python tests/run.py --game out/testgame/data.xp3 --harness tests/harness_click.tjs --click 640,360
  python tests/run.py --game out/testgame/data.xp3 --frames 240 --dump-last

旋钮都通过 -at_* 命令行参数传给引擎，脚本宿主（.tjs）用 System.getArgument 读取；
--arg K=V 可以加任意自定义旋钮。产物默认落在 out/autotest/<时间戳>/。
"""
from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEFAULT_EXE = REPO / "out/windows/Release/krkrsdl3.exe"


def num(value: str, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", default=str(REPO / "out/testgame/data.xp3"),
                    help="data.xp3 或解包目录（引擎的第一个位置参数）")
    ap.add_argument("--exe", default=str(DEFAULT_EXE), help="krkrsdl3 可执行文件")
    ap.add_argument("--harness", default="", help="脚本宿主 .tjs（留空=只按帧数跑）")
    ap.add_argument("--out", default="", help="产物目录，默认 out/autotest/<时间戳>")
    ap.add_argument("--frames", type=int, default=600, help="旅程帧数（宿主读 -at_frames）")
    ap.add_argument("--every", type=int, default=120, help="每多少帧截一张图（宿主读 -at_every）")
    ap.add_argument("--click", action="append", default=[], metavar="X,Y",
                    help="点击坐标，可重复（宿主读 -at_clicks）")
    ap.add_argument("--key", action="append", default=[], metavar="NAME",
                    help="按键（SDL 扫描码名，如 RETURN），可重复（宿主读 -at_keys）")
    ap.add_argument("--type", dest="type_text", default="", help="输入文字（宿主读 -at_type）")
    ap.add_argument("--arg", action="append", default=[], metavar="K=V",
                    help="额外自定义旋钮，转成 -K=V")
    ap.add_argument("--renderer", default="software", choices=["software", "opengl", "vulkan"])
    ap.add_argument("--window", default="1280x720", help="窗口尺寸 WxH")
    ap.add_argument("--visible", action="store_true", help="显示窗口（默认 -offscreen 不显示）")
    ap.add_argument("--dummy", action="store_true", help="SDL_VIDEODRIVER=dummy（无显示环境的 CI 跑法）")
    ap.add_argument("--nosound", dest="silent", action="store_false", default=True,
                    help="真出声（默认 -silent 走 SDL dummy 音频）")
    ap.add_argument("--dump-last", action="store_true", help="退出前把最后一帧写成 last.png")
    ap.add_argument("--timeout", type=int, default=600, help="墙钟超时秒数")
    ap.add_argument("--dry-run", action="store_true", help="只打印将要执行的命令")
    return ap.parse_args()


def build_command(args: argparse.Namespace, out: Path) -> list[str]:
    harness = str(Path(args.harness).resolve().as_posix()) if args.harness else ""
    clicks = ";".join(args.click)
    keys = ";".join(args.key)

    cmd = [str(Path(args.exe).resolve().as_posix()), Path(args.game).resolve().as_posix()]
    cmd += [f"-render={args.renderer}", f"-window={args.window}", "-vsync=0"]
    if not args.visible:
        cmd.append("-offscreen")
    if args.silent:
        cmd.append("-silent")
    # 硬上限：宿主旅程 + 余量，防止脚本卡住时进程不退出
    cmd.append(f"-frames={args.frames + 600}")
    if args.dump_last or not harness:
        cmd.append(f"-dump={(out / 'last.png').as_posix()}")
    if harness:
        cmd.append(f"-at_harness={harness}")
    cmd += [f"-at_out={out.as_posix()}", f"-at_frames={args.frames}", f"-at_every={args.every}"]
    if clicks:
        cmd.append(f"-at_clicks={clicks}")
    if keys:
        cmd.append(f"-at_keys={keys}")
    if args.type_text:
        cmd.append(f"-at_type={args.type_text}")
    for extra in args.arg:
        key, _, value = extra.partition("=")
        cmd.append(f"-{key.lstrip('-')}={value}")
    return cmd


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    args = parse_args()
    stamp = time.strftime("%Y%m%d-%H%M%S")
    out = Path(args.out).resolve() if args.out else (REPO / f"out/autotest/{stamp}")
    out.mkdir(parents=True, exist_ok=True)

    cmd = build_command(args, out)
    print("$ " + " ".join(shlex.quote(part) for part in cmd))
    if args.dry_run:
        return 0

    env = dict(os.environ)
    if args.dummy:
        env["SDL_VIDEODRIVER"] = "dummy"

    log_path = out / "console.log"
    with open(log_path, "wb") as log:
        try:
            code = subprocess.run(cmd, cwd=str(Path(args.exe).resolve().parent),
                                  stdout=log, stderr=subprocess.STDOUT,
                                  timeout=args.timeout).returncode
        except subprocess.TimeoutExpired:
            code = 124
            log.write(b"\n[run.py] timeout\n")

    print(f"exit={code}  out={out}")
    shots = sorted(p.name for p in out.glob("*.png"))
    print("png: " + (", ".join(shots) if shots else "(无)"))
    state = out / "state.txt"
    if state.exists():
        print("--- state.txt ---")
        print(read_text(state).strip())
    tail = read_text(log_path).splitlines()[-15:]
    print("--- console.log 末 15 行 ---")
    print("\n".join(tail))
    return code


def read_text(path: Path) -> str:
    """引擎的文本流默认写 UTF-16LE，控制台日志是 UTF-8，两种都要能吃下。"""
    data = path.read_bytes()
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16", errors="replace")
    return data.decode("utf-8", errors="replace")


if __name__ == "__main__":
    sys.exit(main())
