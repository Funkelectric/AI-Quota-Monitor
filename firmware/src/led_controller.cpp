#include "led_controller.h"

// Active-LOW common-anode LED: analogWrite(pin, 255) = OFF.
static void ledWrite(uint8_t pin, uint8_t brightness) {
  analogWrite(pin, 255 - brightness);
}

void ledInit() {
#ifdef TV154
  // No RGB LED on NM-TV-154: nothing to init.
  return;
#else
  pinMode(PIN_LED_R, OUTPUT);
  pinMode(PIN_LED_G, OUTPUT);
  pinMode(PIN_LED_B, OUTPUT);
  ledWrite(PIN_LED_R, 0);
  ledWrite(PIN_LED_G, 0);
  ledWrite(PIN_LED_B, 0);
#endif
}

void ledTick(uint8_t status) {
#ifdef TV154
  (void)status;
  return;
#else
  unsigned long now = millis();
  switch (status) {
    case ST_OK:
      ledWrite(PIN_LED_R, 0);
      ledWrite(PIN_LED_G, 140);
      ledWrite(PIN_LED_B, 0);
      break;
    case ST_WARN:
      ledWrite(PIN_LED_R, 160);
      ledWrite(PIN_LED_G, 90);
      ledWrite(PIN_LED_B, 0);
      break;
    case ST_CRIT:
      // Breathing red alert.
      if ((now / 500) % 2 == 0) {
        ledWrite(PIN_LED_R, 200);
        ledWrite(PIN_LED_G, 0);
        ledWrite(PIN_LED_B, 0);
      } else {
        ledWrite(PIN_LED_R, 0);
        ledWrite(PIN_LED_G, 0);
        ledWrite(PIN_LED_B, 0);
      }
      break;
    default:  // ST_OFFLINE: slow dim-blue pulse.
      if ((now / 1000) % 2 == 0) {
        ledWrite(PIN_LED_R, 0);
        ledWrite(PIN_LED_G, 0);
        ledWrite(PIN_LED_B, 40);
      } else {
        ledWrite(PIN_LED_R, 0);
        ledWrite(PIN_LED_G, 0);
        ledWrite(PIN_LED_B, 0);
      }
      break;
  }
#endif
}

static uint8_t g_bl = 255;

void backlightInit() {
#ifdef TV154
  // NM-TV-154 backlight GPIO19 is active-low: LOW = full brightness.
  // No LDR on this board, so fixed full-on (tick is a no-op).
  pinMode(PIN_TFT_BL, OUTPUT);
  digitalWrite(PIN_TFT_BL, LOW);
#else
  pinMode(PIN_TFT_BL, OUTPUT);
  analogWrite(PIN_TFT_BL, g_bl);
#endif
}

void backlightSet(uint8_t duty) {
  g_bl = duty;
#ifdef TV154
  analogWrite(PIN_TFT_BL, (uint8_t)(255 - duty));  // active-low: invert
#else
  analogWrite(PIN_TFT_BL, duty);
#endif
}

void backlightTick() {
#ifdef TV154
  return;  // no LDR on NM-TV-154: brightness fixed at init
#else
  // LDR on GPIO34: brighter room -> higher ADC -> brighter backlight.
  // Clamp to a readable floor so the screen never goes fully dark.
  // AUDIT H5: EMA + deadband + fast slew. Raw single-sample stepped ±1/tick
  // (107s full swing); now 4-sample EMA, ±8/tick, ±4 deadband -> <5s room
  // transitions, no dither flicker at thresholds.
  static float ema = -1.0f;
#if defined(ESP32)
  analogSetAttenuation(ADC_11db);
#endif
  int raw = analogRead(PIN_LDR);
  if (ema < 0) ema = (float)raw;
  else ema += ((float)raw - ema) / (float)BL_EMA_N;
  int smooth = (int)(ema + 0.5f);
  uint8_t target = (uint8_t)constrain(map(smooth, 200, 3500, 40, 255), 40, 255);
  int diff = (int)target - (int)g_bl;
  if (abs(diff) <= (int)BL_DEADBAND) return;  // hysteresis: ignore noise
  int step = diff > 0 ? diff : -diff;
  if (step > (int)BL_SLEW_STEP) step = (int)BL_SLEW_STEP;
  int next = (int)g_bl + (diff > 0 ? step : -step);
  if (next > 255) next = 255;
  if (next < 40) next = 40;
  g_bl = (uint8_t)next;
  analogWrite(PIN_TFT_BL, g_bl);
#endif
}
