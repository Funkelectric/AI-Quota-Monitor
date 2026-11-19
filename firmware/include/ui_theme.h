#pragma once
#include <stdint.h>

// Dark dashboard palette: exact RGB565 truncations of the hex targets.
#define COLOR_BG        0x1082  // #0D1117
#define COLOR_CARD      0x10C4  // #161B22
#define COLOR_TEXT      0xFFFF
#define COLOR_DIM       0x8CB3  // #8B949E
#define COLOR_GREEN     0x3DCA  // #3FB950
#define COLOR_AMBER     0xD4C4  // #D29922
#define COLOR_RED       0xFA89  // #F85149
#define COLOR_BLUE      0x2D9D  // info / offline accent
#define COLOR_ICE       0x7EBF  // ice-blue accent (#7FD4FF)
#define COLOR_EDGE      0x2988  // hairline borders (#2A3340)
#define COLOR_GRID      0x1906  // faint panel grid (#1B2230)
#define COLOR_WAVE_TOP  0x2AD1  // quota area top (#2A5A8C)

// Display rotation: 3 = landscape 180° (USB port on the LEFT).
// 1 = landscape (USB on the right). Touch mapping flips to match.
// TV154: square 240x240, rotation 0 matches stock/demo orientation.
#ifdef TV154
#define DISPLAY_ROTATION 0
#else
#define DISPLAY_ROTATION 3
#endif

// Layout (landscape 320x240; TV154: square 240x240).
#ifdef TV154
#define LAYOUT_W        240
#define LAYOUT_H        240
#else
#define LAYOUT_W        320
#define LAYOUT_H        240
#endif
#define HEADER_H        28
#define MARGIN          8
#define CARD_R          6

// TV154 240px geometry (from mock_tv154_render.py audit):
// - hero panel x 8..231 (was 8..311), value anchor 180->132,
// - readoutStrip cols [12,118,216]->[12,92,168], dividers 110/208->84/164.
#ifdef TV154
#define TV154_HERO_X1   231
#define TV154_CENTER_X  132
#define TV154_C0        12
#define TV154_C1        92
#define TV154_C2        168
#define TV154_DIV0      84
#define TV154_DIV1      164
#endif

// Status -> color helper (implemented in screens.cpp).
uint16_t statusColor(uint8_t status);
