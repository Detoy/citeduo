#!/usr/bin/env python3
"""素材过期检查：README 的截图 / GIF / 社交卡是否还和当前产品一致。

截图最容易静默过期的地方是**顶部标题文字**——产品改名后，代码和 README 都改了，
但没人会注意到截图里还是旧名。这个脚本不依赖 OCR，而是量标题文字在像素上的宽度：

    "Academic Paper Explorer" 24px 粗体 → 约 286px 宽
    "CiteDuo"                  同字号   → 约 104px 宽

宽度对不上就说明这张图不是当前版本拍的。同时校验尺寸、GIF 帧率，以及
social-card.html / HomePage.tsx / 仓库 About 里的名字是否一致。

用法:
    python3 scripts/assets/check-assets.py
退出码 0 = 一致，1 = 发现过期素材。
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
# ASSETS_DIR 只用于自测：指向一批旧素材，检查器应当报错。
IMAGES = Path(os.environ.get("ASSETS_DIR") or (REPO / "docs" / "images"))

BLUE_400 = (96, 165, 250)  # tailwind blue-400：应用头部标题的颜色
TOLERANCE = 40
EXPECTED_SHOTS = {  # 文件名 → 期望尺寸
    "network-graph.png": (1920, 1080),
    "two-paper-connection.png": (1920, 1080),
    "compare.png": (1920, 1080),
    "reader-translation.png": (1920, 1080),
    "ai-assistant.png": (1920, 1080),
    "social-preview.png": (1280, 640),
}
TITLE_MAX_WIDTH = 200  # 比这宽就说明标题不是短名（CiteDuo 约 104px）
CARD_TITLE_MAX_HEIGHT = 60  # 社交卡标题单行约 39px；旧名两行是 107px

problems: list[str] = []
notes: list[str] = []


def load_pillow():
    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        print("!! 需要 Pillow: pip install Pillow")
        sys.exit(2)


def title_bbox(img, y_max: int = 60, x_max: int = 400):
    """返回头部区域内 blue-400 文字的包围盒，找不到返回 None。"""
    px = img.load()
    xs, ys = [], []
    for y in range(min(y_max, img.size[1])):
        for x in range(min(x_max, img.size[0])):
            r, g, b = px[x, y][:3]
            if abs(r - BLUE_400[0]) < TOLERANCE and abs(g - BLUE_400[1]) < TOLERANCE and abs(b - BLUE_400[2]) < TOLERANCE:
                xs.append(x)
                ys.append(y)
    return (min(xs), max(xs), min(ys), max(ys)) if xs else None


def white_bbox(img, x_max: int = 640):
    """社交卡的标题是白字（不是应用里的 blue-400）。"""
    px = img.load()
    xs, ys = [], []
    for y in range(img.size[1]):
        for x in range(min(x_max, img.size[0])):
            r, g, b = px[x, y][:3]
            if r > 230 and g > 230 and b > 230:
                xs.append(x)
                ys.append(y)
    return (min(xs), max(xs), min(ys), max(ys)) if xs else None


def app_title() -> str:
    src = (REPO / "academic-paper-explorer" / "src" / "pages" / "HomePage.tsx").read_text(encoding="utf-8")
    m = re.search(r"<h1[^>]*>\s*([^<{]+?)\s*</h1>", src)
    return m.group(1) if m else ""


def card_title() -> str:
    src = (REPO / "scripts" / "assets" / "social-card.html").read_text(encoding="utf-8")
    m = re.search(r"<h1>\s*([^<]+?)\s*</h1>", src)
    return m.group(1) if m else ""


def main() -> int:
    load_pillow()
    from PIL import Image

    name = app_title()
    if not name:
        problems.append("在 HomePage.tsx 里找不到标题（<h1>…</h1>），检查逻辑需要更新")

    card = card_title()
    if card and card != name:
        problems.append(f"社交卡上的名字是 {card!r}，应用里是 {name!r}——重跑 capture-assets.sh card")
    elif card:
        notes.append(f"名字一致: 应用 = 社交卡 = {name!r}")

    for fname, size in EXPECTED_SHOTS.items():
        path = IMAGES / fname
        if not path.exists():
            problems.append(f"缺文件: {fname}")
            continue
        im = Image.open(path).convert("RGB")
        if im.size != size:
            problems.append(f"{fname}: 尺寸 {im.size}，期望 {size}")
            continue

        # 首页截图有蓝色标题；阅读器截图没有（顶部是返回/arXiv/翻译那一行），跳过。
        if fname in {"reader-translation.png", "ai-assistant.png"}:
            notes.append(f"{fname}: 尺寸 {im.size[0]}x{im.size[1]} ✓（阅读器页无蓝色标题，跳过标题检查）")
            continue

        # 社交卡是另做的版面：标题白字、居左单行。旧版两行标题会把这一块撑高。
        if fname == "social-preview.png":
            box = white_bbox(im)
            if box is None:
                problems.append("social-preview.png: 左半边找不到白色标题文字——版面可能变了")
                continue
            height = box[3] - box[2] + 1
            width = box[1] - box[0] + 1
            ok = height <= CARD_TITLE_MAX_HEIGHT
            notes.append(
                f"{fname}: 白字标题 {width}x{height}px "
                f"（单行 {name!r} 约 39px 高，旧名两行约 107px）{'✓' if ok else '✗ 像是两行旧名'}"
            )
            if not ok:
                problems.append(f"social-preview.png: 标题高 {height}px，像是旧的两行标题")
            continue

        box = title_bbox(im)
        if box is None:
            problems.append(f"{fname}: 头部找不到标题文字——版面可能变了")
            continue
        width = box[1] - box[0] + 1
        verdict = "✓" if width <= TITLE_MAX_WIDTH else "✗ 像是旧名（更长的字串）"
        notes.append(f"{fname}: 标题宽 {width}px（{name!r} 约 104px，旧名约 286px）{verdict}")
        if width > TITLE_MAX_WIDTH:
            problems.append(f"{fname}: 标题宽 {width}px > {TITLE_MAX_WIDTH}px，素材是旧名版本的画面")

    gif = IMAGES / "graph-demo.gif"
    if not gif.exists():
        problems.append("缺文件: graph-demo.gif")
    else:
        im = Image.open(gif)
        if im.size != (1200, 750):
            problems.append(f"graph-demo.gif: 尺寸 {im.size}，期望 (1200, 750)")
        frames = getattr(im, "n_frames", 1)
        delay = im.info.get("duration")
        notes.append(f"graph-demo.gif: {im.size[0]}x{im.size[1]}, {frames} 帧, {delay}ms/帧")
        if delay and not 100 <= delay <= 250:
            problems.append(f"graph-demo.gif: 帧间隔 {delay}ms 不合理（初版是 170ms）")
        im.seek(0)
        box = title_bbox(im.convert("RGB"))
        if box is None:
            problems.append("graph-demo.gif: 第一帧找不到标题文字")
        else:
            width = box[1] - box[0] + 1
            if width > TITLE_MAX_WIDTH:
                problems.append(f"graph-demo.gif: 标题宽 {width}px，像是旧名版本")

    for line in notes:
        print("  " + line)
    if problems:
        print("\n!! 发现过期素材：")
        for p in problems:
            print("  - " + p)
        print("\n重拍: bash scripts/assets/capture-assets.sh all（见同目录 README）")
        return 1
    print("\n素材与当前产品一致 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
