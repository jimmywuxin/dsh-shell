#!/usr/bin/env python
"""dsh App 图标生成器（v2 标识）

输入：whale_crop.png（从 v1 图标提取的鲸鱼轮廓 alpha 遮罩，1024 源）
输出：
  ../icon_1024.png              蓝版母版（build.sh 唯一输入）
  ../icon-black-1024.png        黑鲸 + 浅瓷底（黑色变体，主）
  ../icon-black-inverse-1024.png 白鲸 + 黑底（黑色变体，反相）
  ../icon-black-mark-1024.png   纯黑鲸鱼 mark（透明底，1024 画布同比例）
  ../icon-monochrome.png        单色模板（512×384 紧裁，菜单栏用）
  icon_master.svg / icon-black.svg 等可编辑矢量母版

三套变体共用同一套几何：1024 画布 / 824 主体 / 100 边距 / 超椭圆 n=5 /
鲸鱼 512×384（占主体 62%）。**只换配色，不动尺寸、比例与线条**——这是三个
变体「风格一致」的硬保证。改颜色/比例只改本文件常量，重跑即可。
设计口径见 docs/icon-design-spec.md。
"""
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.dirname(HERE)
EDGE = "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"

# ── 几何常量（三变体共用，勿按变体改）────────────────────
CANVAS = 1024
BODY = 824                 # macOS Big Sur 图标网格：824×824 主体
MARGIN = (CANVAS - BODY) // 2
SQUIRCLE_N = 5.0           # 超椭圆指数（Apple 连续圆角近似）
WHALE_W = 512              # 鲸鱼宽度（占主体 62%，与 v1 视觉重量一致）
WHALE_CX, WHALE_CY = 510, 500

# ── 配色方案（唯一允许按变体变化的东西）──────────────────
P_BLUE = {
    "name": "blue",
    "bg": ("#7E97FF", "#4C61F2", "#232F8C"),
    "glow": 0.20,
    "shade": ("#0A1233", 0.32),
    "rim": ("#A8E9FF", 0.24),
    "whale": ("#FFFFFF", "#EDF1FF"),
    "whale_shadow": ("#101A4A", 0.18),
    "tile_shadow": ("#080C28", 0.17),
    "edge": ("#FFFFFF", 0.16),
}

# 黑鲸 + 浅瓷底：字面意义的「黑色鲸鱼图标」，浅色桌面优先
P_INK = {
    "name": "ink",
    "bg": ("#FFFFFF", "#F4F6FA", "#DCE2ED"),
    "glow": 0.00,
    "shade": ("#2A3550", 0.10),
    "rim": ("#0B1220", 0.00),
    "whale": ("#0C0E13", "#1A1E26"),
    "whale_shadow": ("#0B1220", 0.00),
    "tile_shadow": ("#0B1220", 0.14),
    "edge": ("#0B1220", 0.10),
}

# 白鲸 + 黑底：深色桌面 / 强调黑时的反相版
P_INK_INVERSE = {
    "name": "ink-inverse",
    "bg": ("#23262D", "#11141A", "#000000"),
    "glow": 0.10,
    "shade": ("#000000", 0.42),
    "rim": ("#FFFFFF", 0.10),
    "whale": ("#FFFFFF", "#EFF2F8"),
    "whale_shadow": ("#000000", 0.00),
    "tile_shadow": ("#000000", 0.26),
    "edge": ("#FFFFFF", 0.12),
}


def squircle_path(size: int, n: float, steps: int = 720) -> str:
    """超椭圆采样成闭合路径。以画布中心为原点，a=b=size/2。"""
    a = size / 2.0
    cx = CANVAS / 2
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = a * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = a * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append(f"{cx + x:.2f} {cx + y:.2f}")
    return "M " + " L ".join(pts) + " Z"


def build_svg(sq: str, p: dict) -> str:
    wh = WHALE_W
    hh = round(wh * 474 / 632)          # 保持原始长宽比
    wx = round(WHALE_CX - wh / 2)
    wy = round(WHALE_CY - hh / 2)
    top, mid, bottom = p["bg"]
    shade, shade_op = p["shade"]
    rim, rim_op = p["rim"]
    w_top, w_bottom = p["whale"]
    ws_color, ws_op = p["whale_shadow"]
    ts_color, ts_op = p["tile_shadow"]
    e_color, e_op = p["edge"]
    return f"""<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
  <defs>
    <linearGradient id="bg" x1="0.12" y1="0" x2="0.88" y2="1">
      <stop offset="0" stop-color="{top}"/>
      <stop offset="0.44" stop-color="{mid}"/>
      <stop offset="1" stop-color="{bottom}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.34" r="0.62">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="{p['glow']:.2f}"/>
      <stop offset="0.55" stop-color="#FFFFFF" stop-opacity="{p['glow'] * 0.25:.3f}"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="innerShade" x1="0" y1="0.45" x2="0" y2="1">
      <stop offset="0" stop-color="{shade}" stop-opacity="0"/>
      <stop offset="1" stop-color="{shade}" stop-opacity="{shade_op:.2f}"/>
    </linearGradient>
    <linearGradient id="whaleFill" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{w_top}"/>
      <stop offset="0.72" stop-color="{w_top}"/>
      <stop offset="1" stop-color="{w_bottom}"/>
    </linearGradient>
    <filter id="tileShadow" x="-25%" y="-25%" width="150%" height="150%">
      <feGaussianBlur stdDeviation="26"/>
    </filter>
    <filter id="rimBlur" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="7"/>
    </filter>
    <filter id="whaleShadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="9" stdDeviation="14" flood-color="{ws_color}" flood-opacity="{ws_op:.2f}"/>
    </filter>
    <clipPath id="tile"><path d="{sq}"/></clipPath>
    <mask id="whaleMask" maskUnits="userSpaceOnUse" x="0" y="0" width="{CANVAS}" height="{CANVAS}">
      <image xlink:href="whale_crop.png" x="{wx}" y="{wy}" width="{wh}" height="{hh}"/>
    </mask>
  </defs>

  <!-- 落地阴影：让图标在浅色桌面上有重量 -->
  <g transform="translate(0 {MARGIN + 6})">
    <path d="{sq}" fill="{ts_color}" opacity="{ts_op:.2f}" filter="url(#tileShadow)"/>
  </g>

  <g clip-path="url(#tile)">
    <rect x="0" y="0" width="{CANVAS}" height="{CANVAS}" fill="url(#bg)"/>
    <rect x="0" y="0" width="{CANVAS}" height="{CANVAS}" fill="url(#glow)"/>

    <!-- 鲸鱼背后的轮廓光：只留一圈，保证小尺寸不糊 -->
    <g opacity="{rim_op:.2f}" filter="url(#rimBlur)">
      <g transform="translate(-4 -5)" mask="url(#whaleMask)">
        <rect x="0" y="0" width="{CANVAS}" height="{CANVAS}" fill="{rim}"/>
      </g>
    </g>

    <!-- 主体：鲸鱼 -->
    <g filter="url(#whaleShadow)">
      <rect x="{wx}" y="{wy}" width="{wh}" height="{hh}" fill="url(#whaleFill)"
            mask="url(#whaleMask)"/>
    </g>

    <!-- 底部内阴影 + 边缘高光/细边 -->
    <rect x="0" y="0" width="{CANVAS}" height="{CANVAS}" fill="url(#innerShade)"/>
    <path d="{sq}" fill="none" stroke="{e_color}" stroke-opacity="{e_op:.2f}" stroke-width="3"/>
  </g>
</svg>
"""


def render(svg_path: str, out_png: str, size: int = CANVAS) -> None:
    cmd = [
        EDGE, "--headless=new", "--no-sandbox", "--disable-gpu", "--in-process-gpu",
        "--hide-scrollbars", "--force-device-scale-factor=1",
        f"--window-size={size},{size}", "--default-background-color=00000000",
        f"--screenshot={out_png}", f"file://{svg_path}",
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def emit(sq: str, palette: dict, svg_name: str, png_name: str) -> None:
    svg_path = os.path.join(HERE, svg_name)
    with open(svg_path, "w", encoding="utf-8") as fh:
        fh.write(build_svg(sq, palette))
    out = os.path.join(ASSETS, png_name)
    render(svg_path, out)
    print(f"rendered {out}")


def main() -> int:
    sq = squircle_path(BODY, SQUIRCLE_N)

    emit(sq, P_BLUE, "icon_master.svg", "icon_1024.png")
    emit(sq, P_INK, "icon_black.svg", "icon-black-1024.png")
    emit(sq, P_INK_INVERSE, "icon_black_inverse.svg", "icon-black-inverse-1024.png")

    # 纯黑鲸鱼 mark：透明底、1024 画布、与图标内鲸鱼同位同尺寸（可直接当 logo 用）
    from PIL import Image
    whale = Image.open(os.path.join(HERE, "whale_crop.png")).convert("RGBA")
    alpha_small = whale.getchannel("A").resize((WHALE_W, 384), Image.LANCZOS)
    mark = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    ink = Image.new("RGBA", alpha_small.size, (10, 12, 16, 255))
    ink.putalpha(alpha_small)
    mark.alpha_composite(ink, (WHALE_CX - WHALE_W // 2, WHALE_CY - 384 // 2))
    mark_path = os.path.join(ASSETS, "icon-black-mark-1024.png")
    mark.save(mark_path)
    print(f"rendered {mark_path}")

    # 单色模板（菜单栏 / 系统着色）：512×384 紧裁，黑色 + alpha
    mono = Image.new("RGBA", alpha_small.size, (0, 0, 0, 255))
    mono.putalpha(alpha_small)
    mono_path = os.path.join(ASSETS, "icon-monochrome.png")
    mono.save(mono_path)
    print(f"rendered {mono_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
