#!/usr/bin/env python3
"""END OF WORK 1:1 mockup for CYD 320x240.

Reuses mock_hw_render.py palette (exact RGB565), real TFT_eSPI font-2
glyphs, header(), 1x canvas nearest-upscaled x3.

Layout (sums to 240):
  header          0..28   CARD, "END - WORK" + packed LIVE/WIFI/clock, EDGE hairline y=28
  tiny label      y=38    "ENDED WORK" font1 DIM, centered
  work title      y=50    font-2 TEXT, centered, truncated to 292px
  work sub        y=68    font-2 DIM (session - model), centered, truncated to 292px
  hairline        y=88    x13..307 EDGE
  hero            single "END OF WORK" line, vertically centered in 88..196
                  (center y=142), WHITE frame / ICE frame, auto-fit 46px->32px
  dismiss button  8,196,304,32 rounded r=3 outline (pulses EDGE/ICE) + CARD fill
  button label    centered font-2 "TOUCH SCREEN TO DISMISS" DIM
"""
import os
from PIL import Image, ImageDraw, ImageFont
import mock_hw_render as M

W, H = M.W, M.H
S = M.S
BG, CARD, TEXT, DIM, ICE, EDGE = M.BG, M.CARD, M.TEXT, M.DIM, M.ICE, M.EDGE
F1, F6 = M.F1, M.F6

WORK_TITLE = "CYD ask-screen mockup"
WORK_SUB = "curious-meadow - Muse Spark 1.3 Contributor"

HERO = "END OF WORK"
HERO_BIG = M.F6
HERO_SMALL = ImageFont.truetype(M.MONO, 32)
BTN = (8, 196, 304, 32)
HINT = "TOUCH SCREEN TO DISMISS"


def trunc(s, px):
    while len(s) > 1 and M.f2_width(s) > px:
        s = s[:-1]
    return s


def center_f2(d, y, s, fill):
    M.draw_f2(d, ((W - M.f2_width(s)) // 2, y), s, fill)


def screen_endofwork(hero_color):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    M.header(d, "END - WORK")
    lab = "ENDED WORK"
    d.text(((W - int(d.textlength(lab, font=F1))) // 2, 38), lab, font=F1, fill=DIM)
    center_f2(d, 50, trunc(WORK_TITLE, 292), TEXT)
    center_f2(d, 68, trunc(WORK_SUB, 292), DIM)
    d.line([13, 88, 307, 88], fill=EDGE)
    # Single centered hero line in 88..196 (center y=142), auto-fit like fw.
    hf, hs = (HERO_BIG, 46) if d.textlength(HERO, font=HERO_BIG) <= 292 else (HERO_SMALL, 32)
    tw = int(d.textlength(HERO, font=hf))
    d.text(((W - tw) // 2, 142 - hs // 2), HERO, font=hf, fill=hero_color)
    x, y, w, h = BTN
    d.rounded_rectangle([x, y, x + w, y + h], 3, outline=EDGE)
    d.rounded_rectangle([x + 1, y + 1, x + w - 1, y + h - 1], 2, outline=None, fill=CARD)
    center_f2(d, y + (h - 16) // 2, HINT, DIM)
    return img


if __name__ == "__main__":
    outdir = os.path.dirname(os.path.abspath(__file__))
    white = screen_endofwork(TEXT)
    blue = screen_endofwork(ICE)
    white.resize((W * S, H * S), Image.NEAREST).save(os.path.join(outdir, "mockup-endofwork-white.png"))
    blue.resize((W * S, H * S), Image.NEAREST).save(os.path.join(outdir, "mockup-endofwork-blue.png"))
    combo = Image.new("RGB", (W * 2 + 8, H), BG)
    combo.paste(white, (0, 0))
    combo.paste(blue, (W + 8, 0))
    combo.resize(((W * 2 + 8) * S, H * S), Image.NEAREST).save(os.path.join(outdir, "mockup-endofwork.png"))
    print("saved mockup-endofwork-white.png / mockup-endofwork-blue.png / mockup-endofwork.png")
