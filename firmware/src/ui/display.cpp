#include "display.h"
#include <SPI.h>
#include <XPT2046_Touchscreen.h>
#include "config.h"
#include "ui_theme.h"

static TFT_eSPI g_tft;
static SPIClass g_touchSPI(VSPI);
static XPT2046_Touchscreen g_touch(PIN_TOUCH_CS, PIN_TOUCH_IRQ);

void displayInit() {
  g_tft.init();
  g_tft.setRotation(DISPLAY_ROTATION);  // 3 = USB port on the LEFT
  g_tft.fillScreen(TFT_BLACK);
}

TFT_eSPI &display() { return g_tft; }

void touchInit() {
  // Raw touch frame stays fixed (rotation 1); the 180° flip is applied
  // in touchTap so it stays exact regardless of calibration asymmetry.
  g_touchSPI.begin(PIN_TOUCH_CLK, PIN_TOUCH_MISO, PIN_TOUCH_MOSI, PIN_TOUCH_CS);
  g_touch.begin(g_touchSPI);
  g_touch.setRotation(1);
}

static bool s_down = false;
static unsigned long s_downMs = 0;

bool touchTap(uint16_t &x, uint16_t &y) {
  bool pressed = g_touch.touched();
  unsigned long now = millis();
  if (pressed && !s_down) {
    s_down = true;
    s_downMs = now;
    return false;
  }
  if (!pressed && s_down) {
    s_down = false;
    if (now - s_downMs > 600) return false;  // was a hold, not a tap
    TS_Point p = g_touch.getPoint();
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
