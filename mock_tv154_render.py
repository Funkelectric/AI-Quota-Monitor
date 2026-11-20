#!/usr/bin/env python3
"""NM-TV-154 (240x240 square) hardware-honest mockups: 01 QUOTA + 02 WINDOWS.

Reuses glyph/palette/measure code from mock_hw_render.py (imported as M) --
no duplicated approximations. Same RGB565 palette (expand-back verified),
same real TFT_eSPI font-16 blits, same curve sampling as firmware
screens.cpp. 1x canvas nearest-upscaled x3 -> 720x720 PNG.

Layout deltas vs 320x240 v1 (see comments at each site):
- W 320->240 (H unchanged 240): bars 296->216px, right edge 308->228,
  value anchor 180->132, strip columns [12,112,196]->[12,92,168].
- Strip hairline y=H-30 (firmware-exact readoutStrip); v1 mock used H-26
  which puts 16px font-2 values at 226..242 (2px clipped on glass).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mock_hw_render as M  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402

W, H = 240, 240
S = 3
HEADER_H = 28
RIGHT = W - 12  # 228: right margin mirror of v1 (W-12)

# ---- header: same packing law as M.header, W=240 ----
# Measured: section "02 - WINDOWS" spaced = 90+2*12 = 114 -> 6..120;
# clock starts at 128 -> 8px gap, no overlap. "01 - QUOTA": 6..100, gap 28.
def header240(d, section):
    d.rectangle([0, 0, W, HEADER_H], fill=M.CARD)
    M.spaced(d, (6, 7), section, M.DIM)
    live, link, clk = "LIVE", "WIFI", "12:04"
    cx = W - 6
    tw = M.f2_width(live)
    M.draw_f2(d, (cx - tw, 6), live, M.ICE)
    d.ellipse([cx - tw - 8, 11, cx - tw - 2, 17], fill=M.ICE)
    cx -= tw + 12
    tw = M.f2_width(link)
    M.draw_f2(d, (cx - tw, 6), link, M.DIM)
    cx -= tw + 6
    tw = M.f2_width(clk)
    M.draw_f2(d, (cx - tw, 6), clk, M.DIM)
    d.line([0, HEADER_H, W, HEADER_H], fill=M.EDGE)


# ---- 01 hero curve: mirrors M.hero, panel x 8..231 (w=223, was 8..311) ----
# y geometry unchanged (H=240). Marker labels keep the 96px clamp rule.
def hero240(d):
    x0, x1, y0, y1 = 8, 231, 38, 170
    d.rectangle([x0, y0, x1, y1], outline=M.EDGE)
    d.rectangle([x0 + 1, y0 + 1, x1 - 1, y1 - 1], fill=M.BG)
    for gx in range(x0 + 38, x1 - 2, 38):
        d.line([gx, y0 + 2, gx, y1 - 2], fill=M.GRID)
    for gy in range(y0 + 26, y1 - 2, 26):
        d.line([x0 + 2, gy, x1 - 2, gy], fill=M.GRID)
    n = 3
    xs, ys = M.curve_points(n, x0, x1, y0, y1)
    pts = M.sample_curve(xs, ys, x0, x1)
    for (x, y) in pts:
        h = (y1 - 1) - y
        if h <= 0:
            continue
        for b in range(6):
            bh = h // 6 + (1 if b < h % 6 else 0)
            if bh <= 0:
                continue
            by = y + (h * b) // 6
            d.rectangle([x, by, x + 1, by + bh - 1],
                        fill=M.lerp565(0x2AD1, 0x1082, b * 255 // 5))
    for (x, y), (xn, yn) in zip(pts, pts[1:]):
        d.line([x, y, xn, yn], fill=M.ICE)
    placed = []
    for i, (mx, my) in enumerate(zip(xs, ys)):
        mx, my = int(mx), int(my)
        d.ellipse([mx - 3, my - 3, mx + 3, my + 3], outline=M.ICE, fill=M.BG)
        lab = f"{M.short_name(M.DATA[i][0])} {M.DATA[i][1]:.1f}%"
        while len(lab) > 1 and M.f2_width(lab) > 96:
            lab = lab[:-1]
        lw = M.f2_width(lab)
        lx = max(x0 + 2, min(mx - lw // 2, x1 - 2 - lw))
        # 240px rule: label slots are 74px but labels are 60-86px, so
        # neighbours collide. Try below-marker first (v1 law), flip above
        # on bottom-clip OR intersection with an already placed label.
        cands = [my + 6]
        if cands[0] + 13 <= y1 - 2:
            cands.append(my - 19)
        else:
            cands.insert(0, my - 19)
        ly = cands[0]
        for cand in cands:
            if cand < y0 + 2 or cand + 16 > y1 - 2:
                continue
            if not any(lx < px1 and lx + lw > px0 and cand < py1
                       and cand + 16 > py0 for px0, px1, py0, py1 in placed):
                ly = cand
                break
        else:
            ly = min(max(cands[0], y0 + 2), y1 - 2 - 16)
        placed.append((lx, lx + lw, ly, ly + 16))
        M.draw_f2(d, (lx, ly), lab, M.TEXT)


def session240(d, idx=0):
    d.text((8, 176), "SESSION", font=M.F1, fill=M.DIM)
    if len(M.SESS) > 1:
        pager = f"{idx % len(M.SESS) + 1}/{len(M.SESS)}"
        d.text((W - 8 - int(d.textlength(pager, font=M.F1)), 176),
               pager, font=M.F1, fill=M.DIM)
    title, model = M.SESS[idx % len(M.SESS)]
    line = f"{title} - {model}"
    while len(line) > 1 and M.f2_width(line) > W - 16:  # 224px budget
        line = line[:-1]
    M.draw_f2(d, (8, 186), line, M.TEXT)


def strip240(d):
    y = H - 30  # firmware-exact (readoutStrip); values 224..240, no clip
    d.line([8, y, W - 8, y], fill=M.EDGE)
    nx = M.fmt_cd(min(s for _, _, s in M.DATA))
    # Reflowed 320 cols [12,112,196] -> [12,92,168]: "4H 31M"(48px) 168..216.
    for x, lab in [(12, "TOKENS"), (92, "VER"), (168, "NEXT")]:
        d.text((x, y + 5), lab, font=M.F1, fill=M.DIM)
    M.draw_f2(d, (12, y + 14), M.TOK, M.TEXT)
    M.draw_f2(d, (92, y + 14), M.VER, M.TEXT)
    M.draw_f2(d, (168, y + 14), nx, M.ICE)


def screen_tv_ov():
    img = Image.new("RGB", (W, H), M.BG)
    d = ImageDraw.Draw(img)
    header240(d, "01 - QUOTA")
    hero240(d)
    session240(d)
    strip240(d)
    return img


# ---- 02 WINDOWS: mirrors M.screen_providers, anchor 180->132 ----
# Free zone on 240: max label end "GO MONTH" 12+80=92, min countdown
# start "14D 09H" 228-54=174. Anchor 132 -> value 95..170, gaps 3/4px.
# (v1 rule kept: anchor pushed right of true center to clear labels.)
def screen_tv_prov():
    img = Image.new("RGB", (W, H), M.BG)
    d = ImageDraw.Draw(img)
    header240(d, "02 - WINDOWS")
    y = HEADER_H + 6
    for i, (name, pct, sec) in enumerate(M.DATA):
        M.spaced(d, (12, y), name, M.DIM)
        v = f"{pct:.1f}%"
        vw = int(d.textlength(v, font=M.F4))
        d.text((132 - vw // 2, y + 2), v, font=M.F4, fill=M.status(pct))
        cd = M.fmt_cd(sec)
        M.draw_f2(d, (RIGHT - M.f2_width(cd), y + 10), cd, M.TEXT)
        bx, by, bw, bh = 12, y + 46, W - 24, 10  # bar 216px (was 296)
        d.rounded_rectangle([bx, by, bx + bw, by + bh], 3, outline=M.EDGE)
        fw = int(pct / 100 * (bw - 4))
        if fw:
            d.rectangle([bx + 2, by + 2, bx + 2 + fw, by + bh - 2],
                        fill=M.status(pct))
        mx = bx + 2 + int(0.2 * (bw - 4))
        d.line([mx, by + 1, mx, by + bh - 1], fill=M.TEXT)
        y += 64
    return img


if __name__ == "__main__":
    outdir = os.path.dirname(os.path.abspath(__file__))
    # Overlap audit (hardware-honest proof) before render.
    tmp = ImageDraw.Draw(Image.new("RGB", (W, H)))
    sec = "02 - WINDOWS"
    sec_end = 6 + M.f2_width(sec) + 2 * len(sec)
    clk_start = (W - 6 - M.f2_width("LIVE") - 12 - M.f2_width("WIFI")
                 - 6 - M.f2_width("12:04"))
    print(f"header: section ends {sec_end}, clock starts {clk_start}, "
          f"gap {clk_start - sec_end}")
    for name, pct, sec_ in M.DATA:
        v = f"{pct:.1f}%"
        vw = int(tmp.textlength(v, font=M.F4))
        print(f"prov {name}: label ends {12 + M.f2_width(name) + 2 * len(name)}, "
              f"value {132 - vw // 2}..{132 - vw // 2 + vw}, "
              f"cd starts {RIGHT - M.f2_width(M.fmt_cd(sec_))}")
    for name, fn in [("hw-tv154-ov", screen_tv_ov),
                     ("hw-tv154-prov", screen_tv_prov)]:
        img = fn()
        assert img.size == (W, H), img.size
        img.resize((W * S, H * S), Image.NEAREST).save(
            os.path.join(outdir, f"{name}.png"))
        print("saved", name, f"{W}x{H} x{S} -> {W*S}x{H*S}")
