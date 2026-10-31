"""Draw docs/images/adreno-driver-before-after.png from the measured figures.

    python docs/images/make-adreno-chart.py

Figures are from docs/data/adreno-driver-32.0.181.0.md (stack-compare runs of 2026-10-29, same software, only
the Adreno driver differs). Drawn with Pillow; the two series colours are slots 1 and 2 of the reference palette,
which pass the validator (CVD delta E 24.7, normal-vision 33.6) on the light surface used here.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).with_name("adreno-driver-before-after.png")
FONT = "C:/Windows/Fonts/arial.ttf"
BOLD = "C:/Windows/Fonts/arialbd.ttf"

SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK2 = "#52514e"
MUTED = "#8c8b86"
GRID = "#e6e5e1"
BEFORE = "#2a78d6"   # categorical slot 1
AFTER = "#eb6834"    # categorical slot 2
NEUTRAL = "#a9a8a2"
MINUS = "\u2212"

W, H = 1600, 930
img = Image.new("RGB", (W, H), SURFACE)
d = ImageDraw.Draw(img)


def f(size, bold=False):
    return ImageFont.truetype(BOLD if bold else FONT, size)


def text(xy, s, size, fill=INK, bold=False, anchor="la"):
    d.text(xy, s, font=f(size, bold), fill=fill, anchor=anchor)


# --------------------------------------------------------------- header
text((60, 40), "New Adreno driver: GPU (OpenCL) text generation down 69 to 87 %", 42, INK, True)
text((60, 100), "Snapdragon X2 Elite  \u00b7  llama.cpp on the GPU (OpenCL)  \u00b7  same laptop, same software, on AC power", 24, INK2)
text((60, 134), "Tokens per second while the model writes its reply (text generation). Higher is better.", 24, INK2)

# legend
d.rounded_rectangle((60, 184, 84, 208), 4, fill=BEFORE)
text((96, 184), "Driver 32.0.172.2 (before)", 24, INK)
d.rounded_rectangle((420, 184, 444, 208), 4, fill=AFTER)
text((456, 184), "Driver 32.0.181.0 (after)", 24, INK)

# --------------------------------------------------------------- left panel: grouped bars
groups = [
    ("Qwen3 0.6B", "stock llama.cpp", 98.1, 12.8),
    ("Qwen3 4B", "GenieX's llama.cpp", 29.5, 9.0),
    ("Qwen3-Coder 30B", "stock llama.cpp", 26.8, 5.9),
]
x0, x1 = 120, 930
base, per = 740, 4.4          # baseline y; pixels per tok/s
gw = (x1 - x0) / len(groups)
bw, gap = 96, 8

for v in (0, 25, 50, 75, 100):
    y = base - v * per
    d.line((x0 - 10, y, x1, y), fill=GRID if v else MUTED, width=2 if v == 0 else 1)
    text((x0 - 18, y), str(v), 20, MUTED, anchor="rm")

for i, (name, build, b, a) in enumerate(groups):
    cx = x0 + gw * (i + 0.5)
    for j, (val, col) in enumerate(((b, BEFORE), (a, AFTER))):
        left = cx - bw - gap / 2 if j == 0 else cx + gap / 2
        top = base - val * per
        d.rounded_rectangle((left, top, left + bw, base), 4, fill=col)
        d.rectangle((left, base - 4, left + bw, base), fill=col)   # square the baseline end
        text((left + bw / 2, top - 8), f"{val:.1f}", 26, INK, True, anchor="ms")
    change = (a - b) / b * 100
    text((cx, 262), f"{MINUS}{abs(change):.0f} %", 34, INK, True, anchor="ms")
    text((cx, base + 14), name, 26, INK, True, anchor="ma")
    text((cx, base + 46), build, 20, MUTED, anchor="ma")

# --------------------------------------------------------------- right panel: change on everything else
rx0, rx1 = 1010, 1540
text((rx0, 222), "Change after the update,", 26, INK, True)
text((rx0, 252), "by what was measured", 26, INK, True)
lo, hi = -100, 20
sx = (rx1 - rx0) / (hi - lo)


def xof(p):
    return rx0 + (p - lo) * sx


rows = [
    ("GPU token generation, OpenCL", -87, -69, AFTER),
    ("CPU token generation", 1, 4, NEUTRAL),
    ("NPU token generation", -3, 2, NEUTRAL),
    ("GPU via WebGPU (0.6B only)", -2, 3, NEUTRAL),
]
y = 318
for label, a, b, col in rows:
    rng = f"{MINUS}{abs(a)} to {MINUS}{abs(b)} %" if b < 0 else f"{(MINUS + str(abs(a))) if a < 0 else '+' + str(a)} to +{b} %"
    text((rx0, y), label, 22, INK)
    text((rx1, y), rng, 22, INK, True, anchor="ra")
    # a bar from zero to the end of the range that is furthest from it, so the length is the change
    ext = a if abs(a) >= abs(b) else b
    left, right = xof(min(0, ext)), xof(max(0, ext))
    if right - left < 8:
        left, right = xof(0) - (4 if ext < 0 else 0), xof(0) + (0 if ext < 0 else 8)
    d.rounded_rectangle((left, y + 38, right, y + 62), 4, fill=col)
    d.line((xof(0), y + 32, xof(0), y + 68), fill=MUTED, width=2)   # zero, drawn only beside the bar
    y += 104
for p in (-100, -50, 0):
    lab = "0" if p == 0 else f"{MINUS}{abs(p)} %"
    text((xof(p), y - 22), lab, 20, MUTED, anchor="ma")

# --------------------------------------------------------------- footnote
foot = [
    "Surface Laptop, Snapdragon X2 Elite (Adreno X2-85), Windows 11 ARM64, AC power. Same llama.cpp, same models, same OS and NPU driver: only the Adreno",
    "driver changed, and it reproduced new, old, new. 0.6B and 30B: stock llama.cpp b10566; 4B: GenieX's build. Right panel: the range across the models and",
    "runs measured; CPU, NPU and WebGPU did not move. GPU prompt processing was unchanged on the small models but fell 73 % on the 30B.",
]
for i, line in enumerate(foot):
    text((60, 835 + i * 26), line, 19, INK2)

img.save(OUT, optimize=True)
print("wrote", OUT, img.size)
