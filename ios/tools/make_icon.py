"""EasyTalk app icon (simplified from Edmond's concept): full-bleed square —
iOS applies the rounded mask itself — two speech bubbles, no wordmark.

Run (needs Pillow, Poppins Bold and Noto Sans CJK Bold):
  python3 tools/make_icon.py EasyTalk/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 4                      # supersampling
N = 1024 * S
CJK = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"   # face index 2 = Simplified Chinese
LAT = "/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf"

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def gradient(w, h, c1, c2, diag=True):
    g = Image.new("RGB", (w, h))
    px = g.load()
    for y in range(h):
        for x in range(0, w):
            t = ((x + y) / (w + h)) if diag else y / h
            px[x, y] = lerp(c1, c2, t)
    return g

def bubble_mask(box, tail, r):
    m = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle(box, radius=r, fill=255)
    d.polygon(tail, fill=255)
    return m

# background: deep blue diagonal gradient
bg_small = gradient(256, 256, (40, 132, 255), (8, 52, 190))
img = bg_small.resize((N, N), Image.BICUBIC).convert("RGBA")

def shadow(mask, offset=(0, 26 * S), blur=34 * S, alpha=110):
    sh = Image.new("RGBA", (N, N), (0, 20, 80, 0))
    a = mask.point(lambda v: v * alpha // 255)
    sh.putalpha(a)
    sh = sh.transform((N, N), Image.AFFINE, (1, 0, -offset[0], 0, 1, -offset[1]))
    return sh.filter(ImageFilter.GaussianBlur(blur))

# --- white bubble (English), upper left
wb = (150 * S, 180 * S, 650 * S, 560 * S)
wtail = [(250 * S, 520 * S), (360 * S, 540 * S), (215 * S, 660 * S)]
wmask = bubble_mask(wb, wtail, 150 * S)

# --- green bubble (Chinese), lower right, overlapping
gb = (380 * S, 430 * S, 880 * S, 810 * S)
gtail = [(670 * S, 770 * S), (790 * S, 760 * S), (820 * S, 905 * S)]
gmask = bubble_mask(gb, gtail, 150 * S)

img.alpha_composite(shadow(wmask))
white = Image.new("RGBA", (N, N), (255, 255, 255, 255))
img.paste(white, (0, 0), wmask)

img.alpha_composite(shadow(gmask))
green_small = gradient(256, 256, (66, 222, 128), (14, 160, 92))
green = green_small.resize((N, N), Image.BICUBIC).convert("RGBA")
img.paste(green, (0, 0), gmask)

d = ImageDraw.Draw(img)

def centered(text, font, box, fill):
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    cx = (box[0] + box[2]) / 2
    cy = (box[1] + box[3]) / 2
    d.text((cx - (l + r) / 2, cy - (t + b) / 2), text, font=font, fill=fill)

# "Hi" sits in the visible (left/top) part of the white bubble
centered("Hi", ImageFont.truetype(LAT, 230 * S), (150 * S, 170 * S, 560 * S, 470 * S), (18, 84, 230))
centered("你好", ImageFont.truetype(CJK, 200 * S, index=2), (390 * S, 440 * S, 880 * S, 800 * S), (255, 255, 255))

out = img.convert("RGB").resize((1024, 1024), Image.LANCZOS)
out.save(sys.argv[1] if len(sys.argv) > 1 else "AppIcon-1024.png", optimize=True)
print("ok")
