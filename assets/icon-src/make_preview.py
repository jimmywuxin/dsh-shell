#!/usr/bin/env python
"""生成图标展示图（评审用，不参与构建）：

  assets/icon-preview.png             蓝版 v2
  assets/icon-black-preview.png       黑色变体（黑鲸 + 浅瓷底 / 反相黑底）
  assets/icon-black-mark-preview.png  纯黑 mark 的白底 / 深底对照
"""
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.dirname(HERE)

HEI = "/System/Library/Fonts/STHeiti Medium.ttc"
GB = "/System/Library/Fonts/Hiragino Sans GB.ttc"
MONO = "/System/Library/Fonts/Menlo.ttc"

INK = (24, 28, 42, 255)
SUB = (110, 118, 138, 255)
ACCENT = (76, 97, 242, 255)
PANEL = (240, 242, 248, 255)
DARK = (24, 26, 34, 255)


def fonts():
    return {
        "title": ImageFont.truetype(HEI, 46),
        "sub": ImageFont.truetype(GB, 23),
        "h": ImageFont.truetype(HEI, 25),
        "body": ImageFont.truetype(GB, 20),
        "small": ImageFont.truetype(GB, 16),
        "mono": ImageFont.truetype(MONO, 15),
    }


def swatch(d, box, rgb, label, sub, f):
    d.rounded_rectangle(box, radius=16, fill=rgb + (255,),
                        outline=(11, 18, 32, 40), width=1)
    d.text((box[0], box[3] + 8), label, font=f["mono"], fill=INK)
    d.text((box[0], box[3] + 32), sub, font=f["small"], fill=SUB)


def blue_sheet(f):
    W, H = 1600, 1380
    img = Image.new("RGBA", (W, H), (247, 248, 251, 255))
    d = ImageDraw.Draw(img)
    icon = Image.open(os.path.join(ASSETS, "icon_1024.png"))

    d.text((80, 62), "dsh · App 图标 v2", font=f["title"], fill=INK)
    d.text((80, 126), "保留 DeepSeek 鲸鱼标识与蓝色主调，重做容器、层级与尺寸规范", font=f["sub"], fill=SUB)
    img.alpha_composite(icon.resize((430, 430), Image.LANCZOS), (80, 200))

    x, y = 590, 210
    d.text((x, y), "设计要点", font=f["h"], fill=INK)
    rows = [
        ("图形", "鲸鱼剪影 100% 沿用 v1，轮廓、眼睛、腹线均不重绘"),
        ("容器", "824×824 macOS 圆角矩形（100 px 安全边距）"),
        ("层级", "渐变底 → 内阴影 → 鲸鱼 → 冷边光，四层深度"),
        ("调性", "深海蓝、克制、工具感；不做拟物、不加文字"),
    ]
    y += 48
    for k, v in rows:
        d.text((x, y), k, font=f["body"], fill=ACCENT)
        d.text((x + 72, y), v, font=f["body"], fill=INK)
        y += 42

    d.text((x, y + 20), "配色", font=f["h"], fill=INK)
    sx = x
    for hexv, name in [("#7E97FF", "顶部高光"), ("#4C61F2", "品牌主色"),
                       ("#232F8C", "底部深色"), ("#A8E9FF", "冷边光")]:
        rgb = tuple(int(hexv[i:i + 2], 16) for i in (1, 3, 5))
        swatch(d, (sx, y + 66, sx + 150, y + 146), rgb, hexv, name, f)
        sx += 166

    d.rounded_rectangle((60, 640, 1540, 1000), radius=24, fill=PANEL)
    d.text((92, 662), "尺寸阶梯（16 → 256）", font=f["h"], fill=INK)
    lx, baseline = 110, 965
    for sz in (256, 128, 64, 32, 16):
        img.alpha_composite(icon.resize((sz, sz), Image.LANCZOS), (lx, baseline - sz))
        d.text((lx, baseline + 10), f"{sz}px", font=f["small"], fill=SUB)
        lx += sz + 84

    d.rounded_rectangle((60, 1030, 1540, 1350), radius=24, fill=DARK)
    d.text((92, 1056), "深色桌面", font=f["h"], fill=(238, 240, 248, 255))
    dx, b2 = 110, 1280
    for sz in (128, 64, 32, 16):
        img.alpha_composite(icon.resize((sz, sz), Image.LANCZOS), (dx, b2 - sz))
        d.text((dx, b2 + 10), f"{sz}px", font=f["small"], fill=(150, 158, 180, 255))
        dx += 190
    d.text((900, 1170), "深色底仍保形，底部不糊进背景", font=f["body"], fill=(200, 206, 224, 255))
    d.text((900, 1204), "（底色下限收在 #232F8C，不从纯黑起）", font=f["small"], fill=(140, 148, 170, 255))

    out = os.path.join(ASSETS, "icon-preview.png")
    img.save(out)
    return out


def black_sheet(f):
    W, H = 1600, 1420
    img = Image.new("RGBA", (W, H), (247, 248, 251, 255))
    d = ImageDraw.Draw(img)
    ink_icon = Image.open(os.path.join(ASSETS, "icon-black-1024.png"))
    inv_icon = Image.open(os.path.join(ASSETS, "icon-black-inverse-1024.png"))

    d.text((80, 58), "dsh · 黑色鲸鱼图标", font=f["title"], fill=INK)
    d.text((80, 120), "与 v2 蓝版同一套几何（1024/824/100 · 超椭圆 n=5 · 鲸鱼 512×384），只换配色：尺寸、线条、比例不变",
           font=f["sub"], fill=SUB)

    img.alpha_composite(ink_icon.resize((400, 400), Image.LANCZOS), (80, 190))
    img.alpha_composite(inv_icon.resize((400, 400), Image.LANCZOS), (520, 190))
    d.text((80, 600), "A 黑鲸 + 浅瓷底（主）", font=f["body"], fill=INK)
    d.text((520, 600), "B 白鲸 + 黑底（反相）", font=f["body"], fill=INK)

    x, y = 990, 200
    d.text((x, y), "设计要点", font=f["h"], fill=INK)
    rows = [
        ("几何", "与蓝版共用常量，不重画、不改线宽"),
        ("容器", "824×824 / 100 px 边距 / 超椭圆 n=5"),
        ("鲸鱼", "512×384，占主体 62%，落位 x254 y308"),
        ("调性", "单色克制；黑只做一色，不掺蓝、不走灰彩"),
    ]
    y += 48
    for k, v in rows:
        d.text((x, y), k, font=f["body"], fill=ACCENT)
        d.text((x + 72, y), v, font=f["body"], fill=INK)
        y += 42

    d.text((x, 430), "配色", font=f["h"], fill=INK)
    items = [
        ("#0C0E13", "鲸鱼主体 A", "#0C0E13"),
        ("#FFFFFF→#DCE2ED", "瓷底 A", "#F2F5FA"),
        ("#23262D→#000000", "黑底 B", "#1A1D23"),
        ("#0B1220", "细边 / 投影", "#0B1220"),
    ]
    boxes = [(x, 468, x + 150, 522), (x + 170, 468, x + 320, 522),
             (x, 570, x + 150, 624), (x + 170, 570, x + 320, 624)]
    for (hexv, name, col), box in zip(items, boxes):
        rgb = tuple(int(col[i:i + 2], 16) for i in (1, 3, 5))
        swatch(d, box, rgb, hexv, name, f)

    d.rounded_rectangle((60, 700, 1540, 1050), radius=24, fill=PANEL)
    d.text((92, 722), "尺寸阶梯（16 → 256）", font=f["h"], fill=INK)
    lx, baseline = 110, 1015
    for sz in (256, 128, 64, 32, 16):
        img.alpha_composite(ink_icon.resize((sz, sz), Image.LANCZOS), (lx, baseline - sz))
        d.text((lx, baseline + 10), f"{sz}px", font=f["small"], fill=SUB)
        lx += sz + 84

    d.rounded_rectangle((60, 1080, 1540, 1380), radius=24, fill=DARK)
    d.text((92, 1106), "深色桌面", font=f["h"], fill=(238, 240, 248, 255))
    dx, b2 = 110, 1330
    for sz in (128, 64, 32, 16):
        img.alpha_composite(ink_icon.resize((sz, sz), Image.LANCZOS), (dx, b2 - sz))
        d.text((dx, b2 + 10), f"{sz}px", font=f["small"], fill=(150, 158, 180, 255))
        dx += 190
    d.text((760, 1170), "A 浅瓷底在深色桌面反而最跳，适合当 Dock 里的「白棋子」",
           font=f["body"], fill=(200, 206, 224, 255))
    d.text((760, 1206), "B 黑底靠 12% 白细边勾边界，深色下不失形", font=f["small"], fill=(140, 148, 170, 255))

    out = os.path.join(ASSETS, "icon-black-preview.png")
    img.save(out)
    return out


def mark_sheet(f):
    """纯黑 mark 的白底 / 深底对照，确认可直接当 logo 用"""
    mark = Image.open(os.path.join(ASSETS, "icon-black-mark-1024.png"))
    W, H = 1200, 620
    img = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    d = ImageDraw.Draw(img)
    d.rectangle((W // 2, 0, W, H), fill=(18, 20, 26, 255))
    img.alpha_composite(mark.resize((400, 400), Image.LANCZOS), (70, 90))
    white_mark = Image.new("RGBA", mark.size, (255, 255, 255, 255))
    white_mark.putalpha(mark.getchannel("A"))
    img.alpha_composite(white_mark.resize((400, 400), Image.LANCZOS), (650, 90))
    d.text((70, 530), "纯黑 mark · 透明底 1024 · 鲸鱼 512×384 同位", font=f["body"], fill=INK)
    d.text((650, 530), "同一 mark 反白（深色背景用）", font=f["body"], fill=(232, 236, 246, 255))
    out = os.path.join(ASSETS, "icon-black-mark-preview.png")
    img.save(out)
    return out


if __name__ == "__main__":
    f = fonts()
    for p in (blue_sheet(f), black_sheet(f), mark_sheet(f)):
        print("saved", p)
