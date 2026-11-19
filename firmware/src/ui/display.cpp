#include "display.h"
#include <SPI.h>
#include "config.h"
#include "ui_theme.h"
#if HAS_XPT2046
#include <XPT2046_Touchscreen.h>
#endif

static TFT_eSPI g_tft;
#if HAS_XPT2046
static SPIClass g_touchSPI(VSPI);
static XPT2046_Touchscreen g_touch(PIN_TOUCH_CS, PIN_TOUCH_IRQ);
#endif

void displayInit() {
  g_tft.init();
  g_tft.setRotation(DISPLAY_ROTATION);  // 3 = USB port on the LEFT
  g_tft.fillScreen(TFT_BLACK);
}

TFT_eSPI &display() { return g_tft; }

void touchInit() {
#if !HAS_XPT2046
  // TV-154: single top button, no XY touch. Kept as no-op so main.cpp
  // compiles unchanged; navigation falls back to the BOOT/button path.
  return;
#else
  // Raw touch frame stays fixed (rotation 1); the 180° flip is applied
  // in touchTap so it stays exact regardless of calibration asymmetry.
  g_touchSPI.begin(PIN_TOUCH_CLK, PIN_TOUCH_MISO, PIN_TOUCH_MOSI, PIN_TOUCH_CS);
  g_touch.begin(g_touchSPI);
  g_touch.setRotation(1);
#endif
}

#if !HAS_XPT2046
bool touchTap(uint16_t &x, uint16_t &y) {
  (void)x; (void)y;
  return false;
}
#else
static bool s_down = false;
static unsigned long s_downMs = 0;
static TS_Point s_downPt;
static bool s_downValid = false;

bool touchTap(uint16_t &x, uint16_t &y) {
  bool pressed = g_touch.touched();
  unsigned long now = millis();
  if (pressed && !s_down) {
    s_down = true;
    s_downMs = now;
    // AUDIT H9: sample at press, not release (release reads post-lift stale).
    s_downPt = g_touch.getPoint();
    s_downValid = true;
    return false;
  }
  if (!pressed && s_down) {
    s_down = false;
    if (now - s_downMs > 600) { s_downValid = false; return false; }
    if (!s_downValid) return false;
    s_downValid = false;
    TS_Point p = s_downPt;
    // Raw 12-bit -> screen pixels in the fixed raw frame, then flip for
    // DISPLAY_ROTATION 3 (USB on the left).
    long rx = constrain(p.x, TOUCH_RAW_X_MIN, TOUCH_RAW_X_MAX);
    long ry = constrain(p.y, TOUCH_RAW_Y_MIN, TOUCH_RAW_Y_MAX);
    x = (uint16_t)map(rx, TOUCH_RAW_X_MIN, TOUCH_RAW_X_MAX, 0, LAYOUT_W);
    y = (uint16_t)map(ry, TOUCH_RAW_Y_MIN, TOUCH_RAW_Y_MAX, 0, LAYOUT_H);
#if DISPLAY_ROTATION == 3
    x = LAYOUT_W - x;
    y = LAYOUT_H - y;
#endif
    return true;
  }
  return false;
}
#endif
