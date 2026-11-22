#!/usr/bin/env python3
"""END OF TASK 1:1 mockup for CYD 320x240 landscape (CYD version).

Mirrors mock_endofwork_render.py geometry exactly; only the state
differs: hero "END OF TASK" + subline "N agents still running".
Companion to mock_tv154_endotask_render.py (same semantics, 320 width).

Layout (sums to 240, H unchanged):
  header          0..28   CARD, "END - TASK" + packed LIVE/WIFI/clock, EDGE hairline y=28
  tiny label      y=38    "ENDED TASK" font1 DIM, centered
  work title      y=50    font-2 TEXT, centered, truncated to 292px (W-28, like fw)
  work sub        y=68    font-2 DIM, centered, truncated to 292px
  hairline        y=88    x13..307 EDGE
  hero+sub block  centered as one block in 88..196 (center y=142):
                  zone 88..196 (h=108), block = hero + 10px gap + 16px sub.
                  mock 32px hero -> block 58px: hero y=113..145, sub y=155..171
                  (top/bottom clearance 25/25, block center 142).
                  GLASS (fw font2 x3 fits 292 budget): heroH 48 -> block 74px:
                  hero y=105..153, sub y=163..179 (clear 17/17, center 142).
                  ICE solid (recommended, no blink) / TEXT alt frame,
                  auto-fit 46px->32px like fw
  agents subline  font-2 DIM, centered, truncated to 292px
                  e.g. "2 agents still running" / "1 agent still running"
  dismiss button  8,196,304,32 rounded r=3 outline (solid ICE, no pulse) + CARD fill
  button label    centered font-2 "TOUCH SCREEN TO DISMISS" DIM (same as WORK)
RGB565 palette only, no new colors. Reuses header() law from
mock_hw_render.py (no local duplicate).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mock_hw_render as M  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402

W, H = M.W, M.H
S = M.S
BG, CARD, TEXT, DIM, ICE, EDGE = M.BG, M.CARD, M.TEXT, M.DIM, M.ICE, M.EDGE
F1, F6 = M.F1, M.F6

WORK_TITLE = "CYD ask-screen mockup"
WORK_SUB = "curious-meadow - Muse Spark 1.3 Contributor"

SECTION = "END - TASK"
TINY = "ENDED TASK"
HERO = "END OF TASK"
HERO_BIG = M.F6
HERO_SMALL = ImageFont.truetype(M.MONO, 32)
SUB_CANDIDATES = ["2 agents still running", "1 agent still running", "12 agents still running"]
SUB = SUB_CANDIDATES[0]  # canonical 1-digit case for the reference mockup
ZTOP, ZBOT = 88, 196  # content zone: hairline y .. button top
ZCENTER = (ZTOP + ZBOT) // 2  # 142
GAP = 10  # hero-bottom -> sub-top
SUB_H = 16  # font-2 height
BTN = (8, 196, 304, 32)  # same full-width geometry as WORK
HINT = "TOUCH SCREEN TO DISMISS"  # same as WORK (CYD: any tap dismisses)
BUDGET = W - 28  # 292px, mirrors fw LAYOUT_W-28


def trunc(s, px):
    while len(s) > 1 and M.f2_width(s) > px:
        s = s[:-1]
    return s.rstrip()


def center_f2(d, y, s, fill):
    M.draw_f2(d, ((W - M.f2_width(s)) // 2, y), s, fill)


def screen_cyd_endotask(hero_color):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    M.header(d, SECTION)
    d.text(((W - int(d.textlength(TINY, font=F1))) // 2, 38), TINY, font=F1, fill=DIM)
    center_f2(d, 50, trunc(WORK_TITLE, BUDGET), TEXT)
    center_f2(d, 68, trunc(WORK_SUB, BUDGET), DIM)
    d.line([13, 88, W - 13, 88], fill=EDGE)
    # Hero + subline as ONE centered block in 88..196 (center y=142).
    # Block = hero + GAP + sub; hero_y = center - block/2 so the pair
    # (not the hero alone) sits optically centered between hairline and button.
    hf, hs = (HERO_BIG, 46) if d.textlength(HERO, font=HERO_BIG) <= BUDGET else (HERO_SMALL, 32)
    tw = int(d.textlength(HERO, font=hf))
    block = hs + GAP + SUB_H
    hero_y = ZCENTER - block // 2
    sub_y = hero_y + hs + GAP
    d.text(((W - tw) // 2, hero_y), HERO, font=hf, fill=hero_color)
    # Agents-still-running subline: font-2 DIM, part of the centered block.
    center_f2(d, sub_y, trunc(SUB, BUDGET), DIM)
    x, y, w, h = BTN
    d.rounded_rectangle([x, y, x + w, y + h], 3, outline=ICE)
    d.rounded_rectangle([x + 1, y + 1, x + w - 1, y + h - 1], 2, outline=None, fill=CARD)
    center_f2(d, y + (h - 16) // 2, HINT, DIM)
    return img


if __name__ == "__main__":
    outdir = os.path.dirname(os.path.abspath(__file__))
    # Fit audit (hardware-honest proof) before render.
    tmp = ImageDraw.Draw(Image.new("RGB", (W, H)))
    hb46 = int(tmp.textlength(HERO, font=HERO_BIG))
    hb32 = int(tmp.textlength(HERO, font=HERO_SMALL))
    hw46 = int(tmp.textlength("END OF WORK", font=HERO_BIG))
    print(f"hero {HERO!r}: F6-46 {hb46} vs budget {BUDGET} -> {'OVERFLOW' if hb46 > BUDGET else 'fit'}")
    print(f"hero {HERO!r}: 32px {hb32} vs budget {BUDGET} -> {'OVERFLOW' if hb32 > BUDGET else 'fit'}")
    print(f"WORK hero 'END OF WORK': F6-46 {hw46} vs budget {BUDGET} -> {'OVERFLOW' if hw46 > BUDGET else 'fit'}")
    # fw-equivalent: font2 x3/x2 widths (glass truth; mock is conservative wider case)
    print(f"hero fw f2x3 {M.f2_width(HERO)}*3={M.f2_width(HERO) * 3} vs {BUDGET}, "
          f"f2x2 {M.f2_width(HERO)}*2={M.f2_width(HERO) * 2} vs {BUDGET}")
    print(f"hint {HINT!r}: f2 {M.f2_width(HINT)} vs btn inner {BTN[2] - 2}")
    print(f"title {WORK_TITLE!r}: f2 {M.f2_width(WORK_TITLE)} vs budget {BUDGET}")
    print(f"sub {WORK_SUB!r}: f2 {M.f2_width(WORK_SUB)} vs budget {BUDGET}")
    for s in SUB_CANDIDATES:
        print(f"agents-sub {s!r}: f2 {M.f2_width(s)} vs budget {BUDGET} -> "
              f"{'OVERFLOW' if M.f2_width(s) > BUDGET else 'fit'}")
    # Centering asserts for the mock 32px branch (what this PNG shows).
    _hs = 32
    _block = _hs + GAP + SUB_H
    _hero_y = ZCENTER - _block // 2
    _sub_y = _hero_y + _hs + GAP
    print(f"block(mock-32px): hero {_hero_y}..{_hero_y + _hs}, sub {_sub_y}..{_sub_y + SUB_H}, "
          f"block-center {(_hero_y + _sub_y + SUB_H) // 2} vs zone-center {ZCENTER}, "
          f"clear top {_hero_y - ZTOP} / bottom {ZBOT - (_sub_y + SUB_H)}")
    assert _hero_y >= ZTOP, "hero overlaps hairline"
    assert _sub_y + SUB_H <= ZBOT, "subline overlaps button"
    assert (_hero_y + _sub_y + SUB_H) // 2 == ZCENTER, "block not centered"
    assert _hero_y - ZTOP == ZBOT - (_sub_y + SUB_H), "clearances asymmetric"
    # Glass branch (fw font2 x3 fits the 292 budget): heroH=48, block=74.
    _gh, _gb = 48, 48 + GAP + SUB_H
    _gy, _gs = ZCENTER - _gb // 2, ZCENTER - _gb // 2 + 48 + GAP
    print(f"block(glass-x3): hero {_gy}..{_gy + _gh}, sub {_gs}..{_gs + SUB_H}, "
          f"block-center {(_gy + _gs + SUB_H) // 2} vs zone-center {ZCENTER}, "
          f"clear top {_gy - ZTOP} / bottom {ZBOT - (_gs + SUB_H)}")
    assert _gy >= ZTOP and _gs + SUB_H <= ZBOT, "glass block out of zone"
    assert (_gy + _gs + SUB_H) // 2 == ZCENTER, "glass block not centered"
    # Header gap audit.
    sec_end = 6 + M.f2_width(SECTION) + 2 * len(SECTION)
    clk_start = W - 6 - M.f2_width("LIVE") - 12 - M.f2_width("WIFI") - 6 - M.f2_width("12:04")
    print(f"header {SECTION!r}: section ends {sec_end}, clock starts {clk_start}, gap {clk_start - sec_end}")
    assert clk_start - sec_end >= 8, "header overlap"
    ice = screen_cyd_endotask(ICE)
    white = screen_cyd_endotask(TEXT)
    assert ice.size == (W, H), ice.size
    ice.resize((W * S, H * S), Image.NEAREST).save(os.path.join(outdir, "mockup-cyd-endotask-ice.png"))
    white.resize((W * S, H * S), Image.NEAREST).save(os.path.join(outdir, "mockup-cyd-endotask-white.png"))
    combo = Image.new("RGB", (W * 2 + 8, H), BG)
    combo.paste(ice, (0, 0))
    combo.paste(white, (W + 8, 0))
    combo.resize(((W * 2 + 8) * S, H * S), Image.NEAREST).save(os.path.join(outdir, "mockup-cyd-endotask.png"))
    print("saved mockup-cyd-endotask-ice.png / mockup-cyd-endotask-white.png / mockup-cyd-endotask.png")
