#!/usr/bin/env python3
"""生成 App 图标（原创图形，可安全开源）。

仓库里不存放任何第三方角色形象（小猪佩奇等的版权归权利人）。
这个脚本用几何图形画一个通用的卡通小猪脸，生成：
  - Android: mipmap-*/ic_launcher.png、ic_launcher_round.png、
             ic_launcher_foreground.png（自适应图标前景）、ic_launcher_background.png
  - iOS:     Assets.xcassets/AppIcon.appiconset/ 下 Contents.json 里列出的全部尺寸

改了配色或形状后重跑一次即可，输出是确定的（同样输入同样字节）。

用法：
  python3 scripts/gen_app_icons.py            # 生成并覆盖
  python3 scripts/gen_app_icons.py --preview  # 只在 /tmp 出一张 1024 预览图
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
CLIENT = ROOT / "client"
ANDROID_RES = CLIENT / "android/app/src/main/res"
IOS_ICONS = CLIENT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"

# 配色
SKY_TOP = (232, 243, 255)
SKY_BOTTOM = (205, 228, 255)
PINK = (247, 168, 200)
PINK_DARK = (206, 96, 140)
PINK_LIGHT = (252, 208, 228)
PINK_CHEEK = (243, 140, 180)
NOSTRIL = (196, 84, 126)
INK = (64, 48, 58)
WHITE = (255, 255, 255)

# 画布坐标系固定 1024×1024，最后按目标尺寸缩放
BASE = 1024


def _gradient(size: int) -> Image.Image:
    """竖直线性渐变背景。"""
    img = Image.new("RGB", (1, size))
    px = img.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        px[0, y] = tuple(
            round(SKY_TOP[i] + (SKY_BOTTOM[i] - SKY_TOP[i]) * t) for i in range(3)
        )
    return img.resize((size, size), Image.BILINEAR)


def _draw_pig(draw: ImageDraw.ImageDraw, ox: int, oy: int, scale: float) -> None:
    """在 (ox, oy) 处按 scale 画小猪脸，坐标系按 1024 设计稿。"""

    def box(x0, y0, x1, y1):
        return (
            ox + x0 * scale,
            oy + y0 * scale,
            ox + x1 * scale,
            oy + y1 * scale,
        )

    def w(n):
        return max(1, round(n * scale))

    # 耳朵（先画，被头挡住一部分）
    for x0, x1 in ((258, 486), (538, 766)):
        draw.polygon(
            [
                (ox + x0 * scale, oy + 300 * scale),
                (ox + (x0 + 70) * scale, oy + 128 * scale),
                (ox + x1 * scale, oy + 268 * scale),
            ],
            fill=PINK,
            outline=PINK_DARK,
            width=w(16),
        )
        draw.polygon(
            [
                (ox + (x0 + 62) * scale, oy + 292 * scale),
                (ox + (x0 + 94) * scale, oy + 196 * scale),
                (ox + (x1 - 46) * scale, oy + 276 * scale),
            ],
            fill=PINK_LIGHT,
        )

    # 头
    draw.ellipse(box(168, 246, 856, 902), fill=PINK, outline=PINK_DARK, width=w(18))

    # 腮红
    for cx in (300, 724):
        draw.ellipse(
            box(cx - 62, 626, cx + 62, 750),
            fill=PINK_CHEEK,
        )

    # 猪鼻
    draw.ellipse(
        box(372, 548, 652, 764), fill=PINK_LIGHT, outline=PINK_DARK, width=w(16)
    )
    draw.ellipse(box(438, 612, 492, 700), fill=NOSTRIL)
    draw.ellipse(box(532, 612, 586, 700), fill=NOSTRIL)

    # 眼睛
    for cx in (408, 616):
        draw.ellipse(box(cx - 86, 384, cx + 86, 556), fill=WHITE, outline=INK, width=w(12))
        draw.ellipse(box(cx - 40, 430, cx + 40, 510), fill=INK)
        draw.ellipse(box(cx - 12, 440, cx + 18, 470), fill=WHITE)

    # 笑
    draw.arc(box(420, 720, 604, 862), start=15, end=165, fill=INK, width=w(18))


def render(size: int, mode: str = "full") -> Image.Image:
    """渲染一张 size×size 的图。

    mode:
      full  —— 背景 + 小猪（方图，iOS / 传统 launcher）
      round —— 同上，圆形裁切
      fg    —— 透明背景，只有小猪（自适应图标前景）
      bg    —— 只有背景（自适应图标背景）
    """
    ss = 4 if size <= 160 else 2  # 小图多超采样，避免锯齿
    canvas = BASE * ss

    if mode == "bg":
        return _gradient(size)

    if mode == "fg":
        img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    else:
        img = _gradient(canvas).convert("RGBA")

    draw = ImageDraw.Draw(img)

    if mode == "fg":
        # 自适应图标的安全区：内容缩到 60%，居中
        scale = 0.6 * canvas / BASE
        off = (canvas - BASE * scale) / 2
        _draw_pig(draw, off, off, scale)
    else:
        _draw_pig(draw, 0, 0, canvas / BASE)

    img = img.resize((size, size), Image.LANCZOS)

    if mode == "round":
        mask = Image.new("L", (size * 4, size * 4), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
        mask = mask.resize((size, size), Image.LANCZOS)
        out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        out.paste(img, (0, 0), mask)
        img = out

    return img


def write(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG", optimize=True)
    print(f"  ✓ {path.relative_to(ROOT)}  {img.size[0]}×{img.size[1]}")


def gen_android() -> None:
    # 传统 launcher 图标：48dp 基准
    legacy = {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }
    # 自适应图标：108dp 基准
    adaptive = {
        "mdpi": 108,
        "hdpi": 162,
        "xhdpi": 216,
        "xxhdpi": 324,
        "xxxhdpi": 432,
    }
    print("Android:")
    for density, size in legacy.items():
        d = ANDROID_RES / f"mipmap-{density}"
        write(render(size, "full"), d / "ic_launcher.png")
        write(render(size, "round"), d / "ic_launcher_round.png")
    for density, size in adaptive.items():
        d = ANDROID_RES / f"mipmap-{density}"
        write(render(size, "fg"), d / "ic_launcher_foreground.png")
        write(render(size, "bg"), d / "ic_launcher_background.png")


def gen_ios() -> None:
    contents = json.loads((IOS_ICONS / "Contents.json").read_text(encoding="utf-8"))
    print("iOS:")
    seen: dict[tuple[int, str], Path] = {}
    for entry in contents["images"]:
        name = entry.get("filename")
        if not name:
            continue  # 有些槽位留给 1024 之外的用途
        size = round(float(entry["size"].split("x")[0]) * int(entry["scale"].rstrip("x")))
        # iOS 图标不允许透明通道，统一转 RGB
        img = render(size, "full").convert("RGB")
        write(img, IOS_ICONS / name)


def main() -> int:
    if "--preview" in sys.argv:
        out = Path("/tmp/piggypal-icon-preview.png")
        render(512, "full").save(out)
        print(f"预览：{out}")
        return 0

    gen_android()
    gen_ios()
    print("\n完成。图标是脚本画的通用小猪，不含任何第三方角色形象。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
