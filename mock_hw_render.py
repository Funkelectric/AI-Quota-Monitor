#!/usr/bin/env python3
"""Hardware-honest CYD mockups: RGB565 palette, real font sizes, 1x canvas
nearest-upscaled x3. Same curve algorithm as firmware screens.cpp."""
import math
from PIL import Image, ImageDraw, ImageFont

S = 3  # upscale
W, H = 320, 240
HEADER_H = 28
MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"

def c565(c):
    r = ((c >> 11) & 0x1F) * 255 // 31
    g = ((c >> 5) & 0x3F) * 255 // 63
    b = (c & 0x1F) * 255 // 31
    return (r, g, b)

BG = c565(0x1082); CARD = c565(0x10C4); TEXT = c565(0xFFFF)
DIM = c565(0x8CB3); GREEN = c565(0x3DCA); AMBER = c565(0xD4C4)
RED = c565(0xFA89); BLUE = c565(0x2D9D); ICE = c565(0x7EBF)
EDGE = c565(0x2988); GRID = c565(0x1906); WAVETOP = c565(0x2AD1)

def lerp565(a, b, t):
    ar, ag, ab = (a >> 11) & 0x1F, (a >> 5) & 0x3F, a & 0x1F
    br, bg, bb = (b >> 11) & 0x1F, (b >> 5) & 0x3F, b & 0x1F
    r = ar + ((br - ar) * t >> 8); g = ag + ((bg - ag) * t >> 8)
    bl = ab + ((bb - ab) * t >> 8)
    return c565((r << 11) | (g << 5) | bl)

F1 = ImageFont.truetype(MONO, 9)
F2 = ImageFont.truetype(MONO, 15)
F4 = ImageFont.truetype(MONO, 25)
F6 = ImageFont.truetype(MONO, 46)

# ---- Pixel-exact TFT_eSPI font 2 (decoded from Font16.c) ----
def _load_f2():
    import re
    raw = open("/home/enrik/Project/firmware/.pio/libdeps/cyd-st7789/TFT_eSPI/Fonts/Font16.c").read()
    src = re.sub(r"//[^\n]*", "", raw)  # line comments would poison number scans
    toks = re.findall(r"\b\d+\b", re.search(r"widtbl_f16\[96\][^{]*\{(.*?)\};", src, re.DOTALL).group(1))
    wid = [int(x) for x in toks[:96]]
    glyphs = {}
    for m in re.finditer(r"chr_f16_([0-9A-Fa-f]+)\[\d+\][^{]*\{([^}]*)\}", src):
        code = int(m.group(1), 16)  # suffix is the hex ASCII code
        glyphs[code] = [int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", m.group(2))]
    return wid, glyphs

_F2W, _F2G = _load_f2()

def f2_width(s):
    return sum(_F2W[ord(c) - 32] if 32 <= ord(c) < 128 else 6 for c in s)

def draw_f2(d, xy, s, fill, track=0):
    """Blit real TFT_eSPI font-16 glyphs; advance = width (+ tracking)."""
    x, y = xy
    for ch in s:
        code = ord(ch)
        if 32 <= code < 128:
            w = _F2W[code - 32]
            g = _F2G.get(code, [])
            bpr = (w + 6) // 8
            for r in range(16):
                for b in range(bpr):
                    byte = g[r * bpr + b] if r * bpr + b < len(g) else 0
                    for bit in range(8):
                        px = b * 8 + bit
                        if px >= w:
                            break
                        if byte & (0x80 >> bit):
                            d.point((x + px, y + r), fill=fill)
        else:
            w = 6
        x += w + track
    return x

DATA = [("GO 5H", 99.7, 4 * 3600 + 31 * 60), ("GO WEEK", 92.4, 3 * 86400 + 14 * 3600),
        ("GO MONTH", 87.7, 14 * 86400 + 9 * 3600)]
TOK, COST = "14.9k", "$0.00"

def fmt_cd(sec):
    if sec < 3600: return f"{sec // 60}M"
    if sec < 86400: return f"{sec // 3600}H {sec % 3600 // 60:02d}M"
    return f"{sec // 86400}D {sec % 86400 // 3600:02d}H"

def status(p): return RED if p < 20 else (AMBER if p < 50 else GREEN)

def spaced(d, xy, s, fill, track=2, font=None):
    draw_f2(d, xy, s, fill, track)

def header(d, section):
    d.rectangle([0, 0, W, HEADER_H], fill=CARD)
    spaced(d, (6, 7), section, DIM)
    # packed right cluster: LIVE badge, link, clock (mirrors firmware)
    live, link, clk = "LIVE", "WIFI", "12:04"
    cx = W - 6
    tw = f2_width(live)
    draw_f2(d, (cx - tw, 6), live, ICE)
    d.ellipse([cx - tw - 8, 11, cx - tw - 2, 17], fill=ICE)
    cx -= tw + 12
    tw = f2_width(link)
    draw_f2(d, (cx - tw, 6), link, DIM)
    cx -= tw + 6
    tw = f2_width(clk)
    draw_f2(d, (cx - tw, 6), clk, DIM)
    d.line([0, HEADER_H, W, HEADER_H], fill=EDGE)

def short_name(n):
    return n[3:] if len(n) > 3 and n[:3].lower() == "go " else n

def strip(d):
    y = H - 26
    d.line([8, y, W - 8, y], fill=EDGE)
    nx = fmt_cd(min(s for _, _, s in DATA))
    for x, lab in [(12, "TOKENS"), (112, "COST"), (196, "NEXT")]:
        d.text((x, y + 3), lab, font=F1, fill=DIM)
    draw_f2(d, (12, y + 12), TOK, TEXT)
    draw_f2(d, (112, y + 12), COST, TEXT)
    draw_f2(d, (196, y + 12), nx, ICE)

def curve_points(n, x0, x1, y0, y1):
    xs = [x0 + (i + 0.5) * (x1 - x0) / n for i in range(n)]
    ys = [(y1 - 4) - (DATA[i][1] / 100.0) * (y1 - y0 - 22) for i in range(n)]
    return xs, ys

def sample_curve(xs, ys, x0, x1, step=2):
    n = len(xs); out = []
    x = x0
    while x <= x1:
        if n < 2: y = ys[0]
        elif x <= xs[0]: y = ys[0]
        elif x >= xs[-1]: y = ys[-1]
        else:
            k = 0
            while k < n - 2 and x > xs[k + 1]: k += 1
            mu = (x - xs[k]) / (xs[k + 1] - xs[k])
            m = (1 - math.cos(mu * math.pi)) * 0.5
            y = ys[k] + (ys[k + 1] - ys[k]) * m
        out.append((x, int(y))); x += step
    return out

def hero(d):
    x0, x1, y0, y1 = 8, 311, 38, 170
    d.rectangle([x0, y0, x1, y1], outline=EDGE)
    d.rectangle([x0 + 1, y0 + 1, x1 - 1, y1 - 1], fill=BG)
    for gx in range(x0 + 38, x1 - 2, 38): d.line([gx, y0 + 2, gx, y1 - 2], fill=GRID)
    for gy in range(y0 + 26, y1 - 2, 26): d.line([x0 + 2, gy, x1 - 2, gy], fill=GRID)
    n = 3
    xs, ys = curve_points(n, x0, x1, y0, y1)
    pts = sample_curve(xs, ys, x0, x1)
    for (x, y) in pts:
        h = (y1 - 1) - y
        if h <= 0: continue
        for b in range(6):
            bh = h // 6 + (1 if b < h % 6 else 0)
            if bh <= 0: continue
            by = y + (h * b) // 6
            d.rectangle([x, by, x + 1, by + bh - 1],
                        fill=lerp565(0x2AD1, 0x1082, b * 255 // 5))
    for (x, y), (xn, yn) in zip(pts, pts[1:]): d.line([x, y, xn, yn], fill=ICE)
    for i, (mx, my) in enumerate(zip(xs, ys)):
        mx, my = int(mx), int(my)
        d.ellipse([mx - 3, my - 3, mx + 3, my + 3], outline=ICE, fill=BG)
        lab = f"{short_name(DATA[i][0])} {DATA[i][1]:.1f}%"
        while len(lab) > 1 and f2_width(lab) > 96:
            lab = lab[:-1]
        lw = f2_width(lab)
        lx = max(x0 + 2, min(mx - lw // 2, x1 - 2 - lw))
        ly = my + 6
        if ly + 13 > y1 - 2:
            ly = my - 19
        draw_f2(d, (lx, ly), lab, TEXT)
    # WIN inset
    wx, wy, ww, wh = x0 + 5, y1 - 34, 50, 29
    d.rectangle([wx, wy, wx + ww, wy + wh], fill=BG, outline=EDGE)
    d.text((wx + 3, wy + 2), "WIN", font=F1, fill=DIM)
    for i in range(3):
        bh = int(DATA[i][1] / 100 * 17)
        d.rectangle([wx + 5 + i * 14, wy + wh - 3 - bh, wx + 5 + i * 14 + 9, wy + wh - 3],
                    fill=status(DATA[i][1]))
    # SCOPE inset ring, bottom-right (curve runs high, corner stays clear)
    sx, sy, sw, sh = x1 - 62, y1 - 52, 58, 46
    d.rectangle([sx, sy, sx + sw, sy + sh], fill=BG, outline=EDGE)
    d.text((sx + 3, sy + 2), "SCP", font=F1, fill=DIM)
    rcx, rcy, rr = sx + sw - 18, sy + 28, 13
    d.arc([rcx - rr, rcy - rr, rcx + rr, rcy + rr], 0, 360, fill=EDGE, width=4)
    m = min(p for _, p, _ in DATA)
    d.arc([rcx - rr, rcy - rr, rcx + rr, rcy + rr], -90, -90 + int(m / 100 * 360),
          fill=status(m), width=4)
    for i in range(3):
        a = math.radians(i * 120 + 90)
        d.ellipse([rcx + int(rr * math.sin(a)) - 2, rcy - int(rr * math.cos(a)) - 2,
                    rcx + int(rr * math.sin(a)) + 2, rcy - int(rr * math.cos(a)) + 2],
                   fill=status(DATA[i][1]))
    t = f"{m:.0f}"
    draw_f2(d, (rcx - f2_width(t) // 2, rcy - 8), t, TEXT)

def screen_overview():
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    header(d, "01 · QUOTA"); hero(d); strip(d)
    return img

def screen_providers():
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    header(d, "02 · WINDOWS")
    y = HEADER_H + 6
    for i, (name, pct, sec) in enumerate(DATA):
        spaced(d, (12, y), f"P{i + 1} · {name}", AMBER if False else DIM)
        v = f"{pct:.1f}"
        d.text((W - 12 - int(d.textlength(v + "%", font=F4)), y + 12), v, font=F4, fill=status(pct))
        draw_f2(d, (W - 12 - f2_width("%"), y + 32), "%", DIM)
        cd = fmt_cd(sec)
        draw_f2(d, (W - 12 - f2_width(cd), y + 44), cd, DIM)
        bx, by, bw, bh = 12, y + 58, W - 24, 8
        d.rounded_rectangle([bx, by, bx + bw, by + bh], 3, outline=EDGE)
        fw = int(pct / 100 * (bw - 4))
        if fw: d.rectangle([bx + 2, by + 2, bx + 2 + fw, by + bh - 2], fill=status(pct))
        mx = bx + 2 + int(0.2 * (bw - 4))
        d.line([mx, by + 1, mx, by + bh - 1], fill=TEXT)
        y += 66
    return img

def ring(d, cx, cy, r, th, frac, col):
    d.arc([cx - r, cy - r, cx + r, cy + r], 0, 360, fill=EDGE, width=th)
    if frac > 0:
        for deg in range(0, int(frac * 360), 4):
            a0 = math.radians(deg - 90); a1 = math.radians(deg + 4 - 90)
            d.line([cx + int((r - th // 2) * math.cos(a0)), cy + int((r - th // 2) * math.sin(a0)),
                    cx + int((r - th // 2) * math.cos(a1)), cy + int((r - th // 2) * math.sin(a1))],
                   fill=col, width=th)

def screen_scope():
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    header(d, "03 · SCOPE")
    cx, cy, r, th = 74, 128, 46, 10
    d.line([cx - r - 6, cy, cx + r + 6, cy], fill=EDGE)
    d.line([cx, cy - r - 6, cx, cy + r + 6], fill=EDGE)
    for a in range(0, 360, 30):
        rd = math.radians(a)
        d.point((cx + int((r + 5) * math.sin(rd)), cy - int((r + 5) * math.cos(rd))), fill=DIM)
    m = min(p for _, p, _ in DATA)
    ring(d, cx, cy, r, th, m / 100, status(m))
    for i in range(3):
        a = math.radians(i * 120 + 90)
        px, py = cx + int(r * math.sin(a)), cy - int(r * math.cos(a))
        d.ellipse([px - 4, py - 4, px + 4, py + 4], outline=status(DATA[i][1]), width=2)
    t = f"{m:.0f}"
    tw = int(d.textlength(t, font=F4))
    d.text((cx - tw // 2, cy - 17), t, font=F4, fill=TEXT)
    d.text((cx - 26, cy + 24), "MIN LEFT %", font=F1, fill=DIM)
    y = 56
    for i, (name, pct, sec) in enumerate(DATA):
        spaced(d, (140, y), f"P{i + 1} · {name}", DIM)
        v = f"{pct:.1f}"
        d.text((W - 12 - int(d.textlength(v, font=F4)), y + 14), v, font=F4, fill=status(pct))
        cd = fmt_cd(sec)
        draw_f2(d, (W - 12 - f2_width(cd), y + 42), cd, DIM)
        y += 56
    d.text((140, H - 14), "TAP L/R · SCREENS", font=F1, fill=DIM)
    return img

if __name__ == "__main__":
    for name, fn in [("hw-ov", screen_overview), ("hw-prov", screen_providers), ("hw-scope", screen_scope)]:
        fn().resize((W * S, H * S), Image.NEAREST).save(f"/home/enrik/Project/{name}.png")
        print("saved", name)
