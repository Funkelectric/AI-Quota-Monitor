#!/usr/bin/env python3
"""END OF TASK 1:1 mockup for NM-TV-154 240x240 square (TV version only).

Mirrors mock_tv154_endofwork_render.py geometry exactly; only the state
differs: hero "END OF TASK" + subline "N agents still running".

Layout (sums to 240, H unchanged):
  header          0..28   CARD, "END - TASK" + packed LIVE/WIFI/clock, EDGE hairline y=28
  tiny label      y=38    "ENDED TASK" font1 DIM, centered
  work title      y=50    font-2 TEXT, centered, truncated to 212px (W-28, like fw)
  work sub        y=68    font-2 DIM, centered, truncated to 212px
  hairline        y=88    x13..227 EDGE (mirrors CYD 13..307 margin)
  hero+sub block  centered as one block in 88..196 (center y=142):
                  zone 88..196 (h=108), block = hero + 10px gap + 16px sub.
                  32px hero -> block 58px: hero y=113..145, sub y=155..171
                  (top/bottom clearance 25/25, block center 142).
                  ICE solid (recommended, no blink) / TEXT alt frame,
                  auto-fit 46px->32px like fw
  agents subline  font-2 DIM, centered, truncated to 212px
                  e.g. "2 agents still running" / "1 agent still running"
  dismiss button  8,196,224,32 rounded r=3 outline (solid ICE, no pulse) + CARD fill
  button label    centered font-2 "TOUCH TOP TO DISMISS" DIM (148px < 222px inner)
RGB565 palette only, no new colors. Reuses header240() law from
mock_tv154_render.py (no local duplicate).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mock_hw_render as M  # noqa: E402
from mock_tv154_render import header240  # noqa: E402  (shared law, no duplicate)
from PIL import Image, ImageDraw, ImageFont  # noqa: E402

W, H = 240, 240
S = 3
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
BTN = (8, 196, 224, 32)
HINT = "TOUCH TOP TO DISMISS"
BUDGET = W - 28  # 212px, mirrors fw LAYOUT_W-28


def trunc(s, px):
    while len(s) > 1 and M.f2_width(s) > px:
        s = s[:-1]
    return s.rstrip()


def center_f2(d, y, s, fill):
    M.draw_f2(d, ((W - M.f2_width(s)) // 2, y), s, fill)


def screen_tv154_endotask(hero_color):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    header240(d, SECTION)
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
    print(f"hero {HERO!r}: F6-46 {hb46} vs budget {BUDGET} -> {'OVERFLOW' if hb46 > BUDGET else 'fit'}")
    print(f"hero {HERO!r}: 32px {hb32} vs budget {BUDGET} -> {'OVERFLOW' if hb32 > BUDGET else 'fit'}")
    # fw-equivalent: font2 x3/x2 widths (glass truth, mock is conservative wider case)
    print(f"hero fw f2x3 {M.f2_width(HERO) * 3} vs {BUDGET}, f2x2 {M.f2_width(HERO) * 2} vs {BUDGET}")
    print(f"hint {HINT!r}: f2 {M.f2_width(HINT)} vs btn inner {BTN[2] - 2}")
    print(f"title {WORK_TITLE!r}: f2 {M.f2_width(WORK_TITLE)} vs budget {BUDGET}")
    print(f"sub {WORK_SUB!r}: f2 {M.f2_width(WORK_SUB)} vs budget {BUDGET}")
    for s in SUB_CANDIDATES:
        print(f"agents-sub {s!r}: f2 {M.f2_width(s)} vs budget {BUDGET} -> {'OVERFLOW' if M.f2_width(s) > BUDGET else 'fit'}")
    # Centering asserts for the 32px branch: hero 113..145, sub 155..171,
    # block 113..171 center 142 == zone 88..196 center 142, clearances 25/25.
    _hs = 32
    _block = _hs + GAP + SUB_H
    _hero_y = ZCENTER - _block // 2
    _sub_y = _hero_y + _hs + GAP
    print(f"block: hero {_hero_y}..{_hero_y + _hs}, sub {_sub_y}..{_sub_y + SUB_H}, "
          f"block-center {(_hero_y + _sub_y + SUB_H) // 2} vs zone-center {ZCENTER}, "
          f"clear top {_hero_y - ZTOP} / bottom {ZBOT - (_sub_y + SUB_H)}")
    assert _hero_y >= ZTOP, "hero overlaps hairline"
    assert _sub_y + SUB_H <= ZBOT, "subline overlaps button"
    assert (_hero_y + _sub_y + SUB_H) // 2 == ZCENTER, "block not centered"
    assert _hero_y - ZTOP == ZBOT - (_sub_y + SUB_H), "clearances asymmetric"
    # Header gap audit.
    sec_end = 6 + M.f2_width(SECTION) + 2 * len(SECTION)
    clk_start = W - 6 - M.f2_width("LIVE") - 12 - M.f2_width("WIFI") - 6 - M.f2_width("12:04")
    print(f"header {SECTION!r}: section ends {sec_end}, clock starts {clk_start}, gap {clk_start - sec_end}")
    assert clk_start - sec_end >= 8, "header overlap"
    ice = screen_tv154_endotask(ICE)
    white = screen_tv154_endotask(TEXT)
    assert ice.size == (W, H), ice.size
    ice.resize((W * S, H * S), Image.NEAREST).save(os.path.join(outdir, "mockup-tv154-endotask-ice.png"))
    white.resize((W * S, H * S), Image.NEAREST).save(os.path.join(outdir, "mockup-tv154-endotask-white.png"))
    combo = Image.new("RGB", (W * 2 + 8, H), BG)
    combo.paste(ice, (0, 0))
    combo.paste(white, (W + 8, 0))
    combo.resize(((W * 2 + 8) * S, H * S), Image.NEAREST).save(os.path.join(outdir, "mockup-tv154-endotask.png"))
    print("saved mockup-tv154-endotask-ice.png / mockup-tv154-endotask-white.png / mockup-tv154-endotask.png")
