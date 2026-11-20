// TV-154 power/backlight sweep diagnostic (env: tv154-diag).
// Cycles LCD power rail (GPIO21) x backlight (GPIO19) HIGH/LOW combos,
// re-inits the panel each step, fills a distinct color + logs to serial.
// User reports which color (if any) lights the screen.
#include <Arduino.h>
#include <TFT_eSPI.h>

static TFT_eSPI s_tft;

struct Combo {
  uint8_t pwr;
  uint8_t bl;
  const char *name;
  uint16_t color;
};

static const Combo kCombos[] = {
  {LOW, LOW, "0 PWR-LOW BL-LOW white", TFT_WHITE},
  {LOW, HIGH, "1 PWR-LOW BL-HIGH red", TFT_RED},
  {HIGH, LOW, "2 PWR-HIGH BL-LOW green", TFT_GREEN},
  {HIGH, HIGH, "3 PWR-HIGH BL-HIGH blue", TFT_BLUE},
};

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("[diag] tv154 PWR/BL sweep start (4s per step)");
}

void loop() {
  static int i = 0;
  const Combo &c = kCombos[i % 4];
  pinMode(21, OUTPUT);
  digitalWrite(21, c.pwr);
  pinMode(19, OUTPUT);
  delay(250);  // let the rail settle before panel init
  s_tft.init();
  s_tft.setRotation(0);
  s_tft.invertDisplay(true);
  s_tft.fillScreen(c.color);
  digitalWrite(19, c.bl);
  s_tft.setTextColor(TFT_BLACK, c.color);
  s_tft.drawCentreString(c.name, 120, 110, 2);
  Serial.printf("[diag] step %d: %s rawT9=%d REPORT IF VISIBLE\n", i % 4, c.name,
                touchRead(T9));
  delay(4000);
  i++;
}
