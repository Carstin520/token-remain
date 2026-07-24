#!/usr/bin/env python3
"""Render the TokenRemain DMG install-window background.

Outputs Resources/dmg/background.png (@1x) and background@2x.png, which
package_developer_id_release.sh combines into a multi-resolution background.tiff.

Design notes
------------
* Palette follows design/palette.md (site CSS tokens).
* The arrow reuses the brand's segmented quota-bar language.
* The two icon "slots" sit at relative luminance ~0.18. Finder renders icon
  labels in white under Dark Mode and black under Light Mode, and 0.18 is the
  luminance that maximises the *worst-case* contrast of the two (~4.6:1), so the
  "TokenRemain" / "Applications" labels stay readable in either appearance.
"""

from PIL import Image, ImageDraw, ImageFilter, ImageFont
import os

W, H = 640, 448          # @1x content size, must match the Finder window
S = 2                    # supersample factor -> @2x asset

INK        = (0x07, 0x0B, 0x12)
VIOLET     = (0x8F, 0x7B, 0xF2)
CYAN       = (0x3E, 0xCF, 0xE0)
TEXT       = (0xE9, 0xED, 0xF5)
TEXT_DIM   = (0x8B, 0x97, 0xAB)

MONO = "/System/Library/Fonts/SFNSMono.ttf"
SANS = "/System/Library/Fonts/SFNS.ttf"
HAN  = "/System/Library/Fonts/Hiragino Sans GB.ttc"


def font(path, size, weight=None, index=None):
    f = (ImageFont.truetype(path, size * S, index=index)
         if index is not None else ImageFont.truetype(path, size * S))
    if weight:
        try:
            f.set_variation_by_name(weight)
        except Exception:
            pass
    return f


def _lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    r, g, b = (_lin(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def at_luminance(rgb, target):
    """Scale an RGB triple until it hits the requested relative luminance."""
    lo, hi = 0.0, 4.0
    for _ in range(60):
        k = (lo + hi) / 2
        cand = tuple(min(255, max(0, round(c * k))) for c in rgb)
        if luminance(cand) < target:
            lo = k
        else:
            hi = k
    return tuple(min(255, max(0, round(c * (lo + hi) / 2))) for c in rgb)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def px(v):
    return v * S


# Violet-tinted slate pinned to the dual-appearance sweet spot. L=0.18 is where
# the worse of {white text, black text} peaks at ~4.6:1; the halo blur below
# costs ~0.012, so aim slightly high and let the blur settle onto the target.
SLOT      = at_luminance((0x9A, 0x93, 0xB4), 0.193)
SLOT_EDGE = at_luminance((0xB9, 0xB2, 0xD2), 0.30)

img = Image.new("RGB", (px(W), px(H)), INK)

# --- ambient violet glow behind the slots -----------------------------------
glow = Image.new("L", (px(W), px(H)), 0)
gd = ImageDraw.Draw(glow)
gd.ellipse([px(60), px(40), px(580), px(400)], fill=70)
gd.ellipse([px(180), px(120), px(460), px(300)], fill=110)
glow = glow.filter(ImageFilter.GaussianBlur(px(70)))
img = Image.composite(Image.new("RGB", img.size, (0x2A, 0x22, 0x55)), img, glow)

# --- faint pixel grid, echoing the pixel-art mascot -------------------------
grid = Image.new("RGBA", (px(W), px(H)), (0, 0, 0, 0))
gdr = ImageDraw.Draw(grid)
for x in range(0, W + 1, 16):
    gdr.line([(px(x), 0), (px(x), px(H))], fill=(255, 255, 255, 5), width=S)
for y in range(0, H + 1, 16):
    gdr.line([(0, px(y)), (px(W), px(y))], fill=(255, 255, 255, 5), width=S)
img = Image.alpha_composite(img.convert("RGBA"), grid).convert("RGB")

draw = ImageDraw.Draw(img, "RGBA")

# --- icon pedestals ---------------------------------------------------------
# The icons themselves are opaque artwork, so they sit straight on the dark
# background; only a soft pool of light marks where each one belongs.
LEFT_CX, RIGHT_CX = 168, 472
ICON_CY = 196
LABEL_Y0, LABEL_Y1 = 264, 292
PLATE_W = 156

pool = Image.new("L", (px(W), px(H)), 0)
pd = ImageDraw.Draw(pool)
for cx in (LEFT_CX, RIGHT_CX):
    pd.ellipse([px(cx - 96), px(ICON_CY - 74), px(cx + 96), px(ICON_CY + 84)], fill=90)
pool = pool.filter(ImageFilter.GaussianBlur(px(26)))
img = Image.composite(Image.new("RGB", img.size, (0x3A, 0x30, 0x6E)), img, pool)
draw = ImageDraw.Draw(img, "RGBA")

# Only the Finder label needs guaranteed contrast, so the tinted patch is kept
# to the text band instead of covering the whole icon. It is blurred into a soft
# halo: the centre keeps the target luminance while the edges dissolve, which
# reads as lighting rather than as a clickable button.
halo = Image.new("L", (px(W), px(H)), 0)
hd = ImageDraw.Draw(halo)
for cx in (LEFT_CX, RIGHT_CX):
    hd.rounded_rectangle(
        [px(cx - PLATE_W // 2), px(LABEL_Y0), px(cx + PLATE_W // 2), px(LABEL_Y1)],
        radius=px(13), fill=255)
halo = halo.filter(ImageFilter.GaussianBlur(px(7)))
img = Image.composite(Image.new("RGB", img.size, SLOT), img, halo)
draw = ImageDraw.Draw(img, "RGBA")

# --- segmented arrow, in the brand's quota-bar language ---------------------
SEG_N, SEG_W, SEG_H, GAP = 6, 10, 9, 5
ARROW_Y = ICON_CY
total = SEG_N * SEG_W + (SEG_N - 1) * GAP
start = (LEFT_CX + RIGHT_CX) // 2 - (total + 16) // 2

for i in range(SEG_N):
    x0 = start + i * (SEG_W + GAP)
    col = lerp(VIOLET, CYAN, i / (SEG_N - 1))
    alpha = round(120 + 135 * (i / (SEG_N - 1)))
    draw.rounded_rectangle(
        [px(x0), px(ARROW_Y - SEG_H // 2), px(x0 + SEG_W), px(ARROW_Y + SEG_H // 2)],
        radius=px(2), fill=col + (alpha,))

tip = start + total + 16
draw.polygon(
    [(px(tip), px(ARROW_Y - 9)), (px(tip + 13), px(ARROW_Y)), (px(tip), px(ARROW_Y + 9))],
    fill=CYAN + (255,))

# --- wordmark, tagline, instructions ----------------------------------------
f_mark = font(MONO, 25, "Bold")
f_tag  = font(SANS, 12, "Regular")
f_step = font(SANS, 14, "Semibold")
try:
    f_han = font(HAN, 12, index=1)
except Exception:
    f_han = None


def center_text(y, text, fnt, fill):
    w = draw.textlength(text, font=fnt)
    draw.text((px(W) / 2 - w / 2, px(y)), text, font=fnt, fill=fill)


# "Token" + "Remain" split, matching the site wordmark
w1 = draw.textlength("Token", font=f_mark)
w2 = draw.textlength("Remain", font=f_mark)
x0 = px(W) / 2 - (w1 + w2) / 2
draw.text((x0, px(44)), "Token", font=f_mark, fill=TEXT)
draw.text((x0 + w1, px(44)), "Remain", font=f_mark, fill=VIOLET)

center_text(82, "Your AI quota, always in the menu bar", f_tag, TEXT_DIM)
center_text(352, "Drag TokenRemain into Applications", f_step, TEXT)
if f_han:
    center_text(378, "将 TokenRemain 拖入 Applications 完成安装", f_han, TEXT_DIM)

out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "dmg")
os.makedirs(out_dir, exist_ok=True)
img.save(os.path.join(out_dir, "background@2x.png"))
img.resize((W, H), Image.LANCZOS).save(os.path.join(out_dir, "background.png"))

print(f"slot fill {SLOT} L={luminance(SLOT):.3f}  edge {SLOT_EDGE} L={luminance(SLOT_EDGE):.3f}")
print(f"wrote {W}x{H} and {W*S}x{H*S} to Resources/dmg/")
