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
# v2 pure-black redesign: BG panels gone, DIM lifted for arm's-length.
BLACK = (0, 0, 0)
DIM2 = c565(0xAD55)  # (172,170,172): +~35% luminance vs DIM, keeps label/value hierarchy

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
F6B = ImageFont.truetype(MONO, 92)  # standby clock: font6 x2 scale

# ---- Pixel-exact TFT_eSPI font 2 (decoded from Font16.c) ----
def _load_f2():
    import re, os
    candidates = [
        "firmware/.pio/libdeps/cyd-st7789/TFT_eSPI/Fonts/Font16.c",
        "/home/enrik/Project/firmware/.pio/libdeps/cyd-st7789/TFT_eSPI/Fonts/Font16.c",
        os.path.join(os.path.dirname(__file__), "firmware/.pio/libdeps/cyd-st7789/TFT_eSPI/Fonts/Font16.c"),
    ]
    raw = None
    for p in candidates:
        try:
            raw = open(p).read()
            break
        except FileNotFoundError:
            continue
    if raw is None:
        raise FileNotFoundError(f"Font16.c not found, tried: {candidates}")
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
TOK, VER, COST = "14.9k", "v0.4", "$0.00"
SESS = [("ESP32 display choice bu", "Muse Spark 1.3 Contributor"),
        ("Pure-black redesign", "Muse Spark 1.3 Contributor"),
        ("CYD ask-screen mockup", "Muse Spark 1.3 Contributor")]

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
    for x, lab in [(12, "TOKENS"), (112, "VER"), (196, "NEXT")]:
        d.text((x, y + 3), lab, font=F1, fill=DIM)
    draw_f2(d, (12, y + 12), TOK, TEXT)
    draw_f2(d, (112, y + 12), VER, TEXT)
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
    # NOTE: WIN + SCOPE insets removed (01 shows session rotator instead).

def session_strip(d, idx=0):
    d.text((8, 176), "SESSION", font=F1, fill=DIM)
    if len(SESS) > 1:
        pager = f"{idx % len(SESS) + 1}/{len(SESS)}"
        d.text((W - 8 - int(d.textlength(pager, font=F1)), 176), pager, font=F1, fill=DIM)
    title, model = SESS[idx % len(SESS)]
    line = f"{title} - {model}"
    while len(line) > 1 and f2_width(line) > W - 16:
        line = line[:-1]
    draw_f2(d, (8, 186), line, TEXT)

def screen_overview():
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    header(d, "01 - QUOTA"); hero(d); session_strip(d); strip(d)
    return img

def screen_providers():
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    header(d, "02 - WINDOWS")
    y = HEADER_H + 6
    for i, (name, pct, sec) in enumerate(DATA):
        spaced(d, (12, y), name, DIM)
        v = f"{pct:.1f}%"
        vw = int(d.textlength(v, font=F4))
        d.text((180 - vw // 2, y + 2), v, font=F4, fill=status(pct))
        cd = fmt_cd(sec)
        draw_f2(d, (W - 12 - f2_width(cd), y + 10), cd, TEXT)
        bx, by, bw, bh = 12, y + 46, W - 24, 10
        d.rounded_rectangle([bx, by, bx + bw, by + bh], 3, outline=EDGE)
        fw = int(pct / 100 * (bw - 4))
        if fw: d.rectangle([bx + 2, by + 2, bx + 2 + fw, by + bh - 2], fill=status(pct))
        mx = bx + 2 + int(0.2 * (bw - 4))
        d.line([mx, by + 1, mx, by + bh - 1], fill=TEXT)
        y += 64
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
    header(d, "03 - SCOPE")
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
        spaced(d, (140, y), f"P{i + 1} - {name}", DIM)
        v = f"{pct:.1f}"
        d.text((W - 12 - int(d.textlength(v, font=F4)), y + 14), v, font=F4, fill=status(pct))
        cd = fmt_cd(sec)
        draw_f2(d, (W - 12 - f2_width(cd), y + 42), cd, DIM)
        y += 56
    d.text((140, H - 14), "TAP L/R - SCREENS", font=F1, fill=DIM)
    return img

def header2(d, section):
    """v2 header: pure BLACK fill (no CARD panel), DIM2 section, packed right cluster."""
    d.rectangle([0, 0, W, HEADER_H], fill=BLACK)
    spaced(d, (10, 6), section, DIM2)
    live, link, clk = "LIVE", "WIFI", "12:04"
    cx = W - 10
    tw = f2_width(live)
    draw_f2(d, (cx - tw, 6), live, ICE)
    dx = cx - tw - 10
    d.ellipse([dx - 4, 10, dx + 4, 18], fill=ICE)
    cx = dx - 14
    tw = f2_width(link)
    draw_f2(d, (cx - tw, 6), link, DIM2)
    cx -= tw + 8
    tw = f2_width(clk)
    draw_f2(d, (cx - tw, 6), clk, DIM2)
    d.line([0, HEADER_H, W, HEADER_H], fill=EDGE)

def strip2(d):
    y = H - 30  # hairline 210, labels 215, values 224..240 (mirrors readoutStrip)
    d.line([8, y, W - 8, y], fill=EDGE)
    nx = fmt_cd(min(s for _, _, s in DATA))
    for x, lab in [(12, "TOKENS"), (112, "VER"), (196, "NEXT")]:
        d.text((x, y + 5), lab, font=F1, fill=DIM2)
    draw_f2(d, (12, y + 14), TOK, TEXT)
    draw_f2(d, (112, y + 14), VER, TEXT)
    draw_f2(d, (196, y + 14), nx, ICE)

def wstatus(p):
    return ("OK", GREEN) if p >= 50 else (("WARN", AMBER) if p >= 20 else ("CRIT", RED))

def solid_bar(d, x, y, w, h, pct, col):
    d.rounded_rectangle([x, y, x + w, y + h], 3, outline=EDGE)
    fw = int(pct / 100 * (w - 4))
    if fw:
        d.rectangle([x + 2, y + 2, x + 2 + fw, y + h - 2], fill=col)
    mx = x + 2 + int(0.2 * (w - 4))
    d.line([mx, y + 1, mx, y + h - 1], fill=TEXT)

def screen_ov2():
    """01 QUOTA v2: 3 big rows (label + font4 % + h13 bar + countdown), strip."""
    img = Image.new("RGB", (W, H), BLACK); d = ImageDraw.Draw(img)
    header2(d, "01 - QUOTA")
    for i, (name, pct, sec) in enumerate(DATA):
        Y = [36, 92, 148][i]
        draw_f2(d, (12, Y), short_name(name), TEXT)
        v = f"{pct:.1f}%"
        d.text((308 - int(d.textlength(v, font=F4)), Y - 4), v, font=F4, fill=status(pct))
        solid_bar(d, 12, Y + 24, 296, 13, pct, status(pct))
        draw_f2(d, (12, Y + 40), fmt_cd(sec), DIM2)
    strip2(d)
    return img

def screen_prov2():
    """02 WINDOWS v2: font6 % + status dot + white reset + h14 bars, full height."""
    img = Image.new("RGB", (W, H), BLACK); d = ImageDraw.Draw(img)
    header2(d, "02 - WINDOWS")
    for i, (name, pct, sec) in enumerate(DATA):
        Y = [34, 104, 174][i]
        col = status(pct)
        d.ellipse([18 - 5, Y + 8 - 5, 18 + 5, Y + 8 + 5], fill=col)
        draw_f2(d, (30, Y), name, TEXT)
        v = f"{pct:.1f}%"
        d.text((308 - int(d.textlength(v, font=F6)), Y - 2), v, font=F6, fill=col)
        draw_f2(d, (30, Y + 20), fmt_cd(sec), TEXT)
        solid_bar(d, 12, Y + 44, 296, 14, pct, col)
    return img

def screen_scope2():
    """03 SCOPE v2: thick ring + font6 MIN + status word left, compact rows right."""
    img = Image.new("RGB", (W, H), BLACK); d = ImageDraw.Draw(img)
    header2(d, "03 - SCOPE")
    cx, cy, r, th = 80, 122, 44, 14
    m = min(p for _, p, _ in DATA)
    ring(d, cx, cy, r, th, m / 100, status(m))
    for i in range(3):
        a = math.radians(i * 120 + 90)
        px, py = cx + int(r * math.sin(a)), cy - int(r * math.cos(a))
        d.ellipse([px - 4, py - 4, px + 4, py + 4], fill=status(DATA[i][1]))
    t = f"{m:.0f}"
    tw = int(d.textlength(t, font=F6))
    d.text((cx - tw // 2, cy - 23), t, font=F6, fill=TEXT)
    lab = "MIN LEFT %"
    draw_f2(d, (cx - f2_width(lab) // 2, cy + 48), lab, DIM2)
    word, wcol = wstatus(m)
    d.ellipse([50 - 5, 204 - 5, 50 + 5, 204 + 5], fill=wcol)
    draw_f2(d, (60, 196), word, wcol)
    for i, (name, pct, sec) in enumerate(DATA):
        Y = [46, 102, 158][i]
        draw_f2(d, (150, Y), short_name(name), TEXT)
        v = f"{pct:.1f}%"
        d.text((308 - int(d.textlength(v, font=F4)), Y - 2), v, font=F4, fill=status(pct))
        solid_bar(d, 150, Y + 24, 158, 10, pct, status(pct))
    d.text((150, 222), "TAP L/R - SCREENS", font=F1, fill=DIM2)
    return img

def screen_clock2():
    """04 STANDBY v2: font6-x2 desk clock, date+status, 3 labeled h12 bars."""
    img = Image.new("RGB", (W, H), BLACK); d = ImageDraw.Draw(img)
    header2(d, "04 - STANDBY")
    hm = "12:04"
    tw = int(d.textlength(hm, font=F6B))
    d.text(((W - tw) // 2, 50), hm, font=F6B, fill=TEXT)
    date, st = "2026-11-19  ", "SYNCED"
    w1, w2 = f2_width(date), f2_width(st)
    x0 = (W - w1 - w2) // 2
    x0 = draw_f2(d, (x0, 150), date, DIM2)
    draw_f2(d, (x0, 150), st, ICE)
    for i, (name, pct, sec) in enumerate(DATA):
        Y = [176, 194, 212][i]
        draw_f2(d, (12, Y), short_name(name), TEXT)
        solid_bar(d, 76, Y + 2, 232, 12, pct, status(pct))
    return img

ASK_Q = "Which model for refactor?"
ASK_SUB = "session: curious-meadow - 2m ago"
ASK_OPTS = [("1 - Quick", "small diff, cheap"),
            ("2 - Full", "thorough refactor"),
            ("3 - Skip", "decide later")]
ASK_FOCUS = 1  # pending/selected option index; ICE outline + ICE text
# Button hitboxes (x, y, w, h). 3-up: (304-2*6)/3 -> 97,97,98.
ASK_BTNS_3 = [(8, 172, 97, 48), (111, 172, 97, 48), (214, 172, 98, 48)]
# 2-option fallback: (304-6)/2 = 149 wide.
ASK_BTNS_2 = [(8, 172, 149, 48), (163, 172, 149, 48)]
# 1-option centered (AUDIT M6, mirrors firmware ASK_SINGLE_*): 148 wide.
ASK_BTNS_1 = [(86, 172, 148, 48)]
# 4-option fallback 2x2 grid, 44px rows: (304-6)/2 wide.
ASK_BTNS_4 = [(8, 124, 149, 44), (163, 124, 149, 44),
              (8, 174, 149, 44), (163, 174, 149, 44)]

def ask_buttons(d, labels, boxes, focus):
    for i, ((x, y, w, h), lab) in enumerate(zip(boxes, labels)):
        col = ICE if i == focus else EDGE
        d.rounded_rectangle([x, y, x + w, y + h], 3, outline=col)
        d.rounded_rectangle([x + 1, y + 1, x + w - 1, y + h - 1], 2, outline=None, fill=CARD)
        tw = f2_width(lab)
        draw_f2(d, (x + (w - tw) // 2, y + (h - 16) // 2), lab, ICE if i == focus else DIM)

def screen_ask():
    img = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(img)
    header(d, "05 - ASK")
    # Question card 8..311 x 34..162 (mirrors hero/meterBar hairlines).
    d.rounded_rectangle([8, 34, 311, 162], 4, outline=EDGE)
    d.rounded_rectangle([9, 35, 310, 161], 3, outline=None, fill=BG)
    d.text((13, 38), "OPENCODE ASKS", font=F1, fill=DIM)
    q = ASK_Q
    while len(q) > 1 and f2_width(q) > 292:
        q = q[:-1]
    draw_f2(d, (13, 50), q, TEXT)
    sub = ASK_SUB
    while len(sub) > 1 and f2_width(sub) > 292:
        sub = sub[:-1]
    draw_f2(d, (13, 68), sub, DIM)
    d.line([13, 88, 307, 88], fill=EDGE)
    y = 94
    for i, (short, desc) in enumerate(ASK_OPTS):
        row = f"{short} - {desc}"
        while len(row) > 1 and f2_width(row) > 292:
            row = row[:-1]
        num, rest = row.split(" ", 1)[0], row.split(" ", 1)[1]
        nx = draw_f2(d, (13, y), num, ICE if i == ASK_FOCUS else DIM)
        draw_f2(d, (nx, y), rest, TEXT if i == ASK_FOCUS else DIM)
        y += 18
    ask_buttons(d, [s for s, _ in ASK_OPTS], ASK_BTNS_3, ASK_FOCUS)
    hint = "TAP TO ANSWER - BOOT = NEXT"
    d.text(((W - int(d.textlength(hint, font=F1))) // 2, 226), hint, font=F1, fill=DIM)
    return img

if __name__ == "__main__":
    import os
    outdir = os.path.dirname(os.path.abspath(__file__))
    for name, fn in [("hw-ov", screen_overview), ("hw-prov", screen_providers), ("hw-scope", screen_scope), ("hw-ask", screen_ask),
                     ("hw-ov2", screen_ov2), ("hw-prov2", screen_prov2), ("hw-scope2", screen_scope2), ("hw-clock2", screen_clock2)]:
        fn().resize((W * S, H * S), Image.NEAREST).save(os.path.join(outdir, f"{name}.png"))
        print("saved", name)
