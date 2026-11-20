#!/usr/bin/env python3
"""END OF WORK 1:1 mockup for NM-TV-154 240x240 square.

Mirrors mock_endofwork_render.py (CYD 320x240) adapted to 240px width.
Reuses mock_hw_render.py palette (exact RGB565), real TFT_eSPI font-2
glyphs, header240() packing law from mock_tv154_render.py, 1x canvas
nearest-upscaled x3 -> 720x720 PNG.

Layout (sums to 240, H unchanged):
  header          0..28   CARD, "END - WORK" + packed LIVE/WIFI/clock, EDGE hairline y=28
  tiny label      y=38    "ENDED WORK" font1 DIM, centered
  work title      y=50    font-2 TEXT, centered, truncated to 224px (W-16, like session240)
  work sub        y=68    font-2 DIM, centered, truncated to 224px
  hairline        y=88    x13..227 EDGE (mirrors CYD 13..307 margin)
  hero "END OF"  y=96    font6 (F6 46px, 166px wide) centered, WHITE frame / ICE frame
  hero "WORK"    y=146   font6 (F6 46px, 110px wide) centered, WHITE frame / ICE frame
  dismiss button  8,196,224,32 rounded r=3 EDGE outline + CARD fill (top tap dismisses)
  button label    centered font-2 "TOUCH TOP TO DISMISS" DIM (148px < 222px inner)
RGB565 palette only, no new colors.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mock_hw_render as M  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402

W, H = 240, 240
S = 3
HEADER_H = 28
BG, CARD, TEXT, DIM, ICE, EDGE = M.BG, M.CARD, M.TEXT, M.DIM, M.ICE, M.EDGE
F1, F6 = M.F1, M.F6

WORK_TITLE = "CYD ask-screen mockup"
WORK_SUB = "curious-meadow - Muse Spark 1.3 Contributor"

HERO = ["END OF", "WORK"]
BTN = (8, 196, 224, 32)
HINT = "TOUCH TOP TO DISMISS"
BUDGET = W - 16  # 224px, like session240


def header240(d, section):
    d.rectangle([0, 0, W, HEADER_H], fill=CARD)
    M.spaced(d, (6, 7), section, DIM)
    live, link, clk = "LIVE", "WIFI", "12:04"
    cx = W - 6
    tw = M.f2_width(live)
    M.draw_f2(d, (cx - tw, 6), live, ICE)
    d.ellipse([cx - tw - 8, 11, cx - tw - 2, 17], fill=ICE)
    cx -= tw + 12
    tw = M.f2_width(link)
    M.draw_f2(d, (cx - tw, 6), link, DIM)
    cx -= tw + 6
    tw = M.f2_width(clk)
    M.draw_f2(d, (cx - tw, 6), clk, DIM)
    d.line([0, HEADER_H, W, HEADER_H], fill=EDGE)


def trunc(s, px):
    while len(s) > 1 and M.f2_width(s) > px:
        s = s[:-1]
    return s.rstrip()


def center_f2(d, y, s, fill):
    M.draw_f2(d, ((W - M.f2_width(s)) // 2, y), s, fill)


def screen_tv154_endofwork(hero_color):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    header240(d, "END - WORK")
    lab = "ENDED WORK"
    d.text(((W - int(d.textlength(lab, font=F1))) // 2, 38), lab, font=F1, fill=DIM)
    center_f2(d, 50, trunc(WORK_TITLE, BUDGET), TEXT)
    center_f2(d, 68, trunc(WORK_SUB, BUDGET), DIM)
    d.line([13, 88, W - 13, 88], fill=EDGE)
    for i, line in enumerate(HERO):
        tw = int(d.textlength(line, font=F6))
        d.text(((W - tw) // 2, 96 + i * 50), line, font=F6, fill=hero_color)
    x, y, w, h = BTN
    d.rounded_rectangle([x, y, x + w, y + h], 3, outline=EDGE)
    d.rounded_rectangle([x + 1, y + 1, x + w - 1, y + h - 1], 2, outline=None, fill=CARD)
    center_f2(d, y + (h - 16) // 2, HINT, DIM)
    return img


if __name__ == "__main__":
    outdir = os.path.dirname(os.path.abspath(__file__))
    # Fit audit (hardware-honest proof) before render.
    tmp = ImageDraw.Draw(Image.new("RGB", (W, H)))
    for line in HERO:
        print(f"hero {line!r}: F6 width {int(tmp.textlength(line, font=F6))} vs W {W}")
    print(f"hint {HINT!r}: f2 {M.f2_width(HINT)} vs btn inner {BTN[2] - 2}")
    print(f"title {WORK_TITLE!r}: f2 {M.f2_width(WORK_TITLE)} vs budget {BUDGET} -> {trunc(WORK_TITLE, BUDGET)!r}")
    print(f"sub {WORK_SUB!r}: f2 {M.f2_width(WORK_SUB)} vs budget {BUDGET} -> {trunc(WORK_SUB, BUDGET)!r}")
    white = screen_tv154_endofwork(TEXT)
    blue = screen_tv154_endofwork(ICE)
    assert white.size == (W, H), white.size
    white.resize((W * S, H * S), Image.NEAREST).save(os.path.join(outdir, "mockup-tv154-endofwork-white.png"))
    blue.resize((W * S, H * S), Image.NEAREST).save(os.path.join(outdir, "mockup-tv154-endofwork-blue.png"))
    combo = Image.new("RGB", (W * 2 + 8, H), BG)
    combo.paste(white, (0, 0))
    combo.paste(blue, (W + 8, 0))
    combo.resize(((W * 2 + 8) * S, H * S), Image.NEAREST).save(os.path.join(outdir, "mockup-tv154-endofwork.png"))
    print("saved mockup-tv154-endofwork-white.png / mockup-tv154-endofwork-blue.png / mockup-tv154-endofwork.png")
