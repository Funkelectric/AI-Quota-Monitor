#include "led_controller.h"

// Active-LOW common-anode LED: analogWrite(pin, 255) = OFF.
static void ledWrite(uint8_t pin, uint8_t brightness) {
  analogWrite(pin, 255 - brightness);
}

void ledInit() {
  pinMode(PIN_LED_R, OUTPUT);
  pinMode(PIN_LED_G, OUTPUT);
  pinMode(PIN_LED_B, OUTPUT);
  ledWrite(PIN_LED_R, 0);
  ledWrite(PIN_LED_G, 0);
  ledWrite(PIN_LED_B, 0);
}

void ledTick(uint8_t status) {
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
}

static uint8_t g_bl = 255;

void backlightInit() {
  pinMode(PIN_TFT_BL, OUTPUT);
  analogWrite(PIN_TFT_BL, g_bl);
}

void backlightSet(uint8_t duty) {
  g_bl = duty;
  analogWrite(PIN_TFT_BL, duty);
}

void backlightTick() {
  // LDR on GPIO34: brighter room -> higher ADC -> brighter backlight.
  // Clamp to a readable floor so the screen never goes fully dark.
  int raw = analogRead(PIN_LDR);
  uint8_t target = (uint8_t)constrain(map(raw, 200, 3500, 40, 255), 40, 255);
  // Ease toward target to avoid flicker on noisy readings.
  if (target > g_bl) g_bl++;
  else if (target < g_bl) g_bl--;
  analogWrite(PIN_TFT_BL, g_bl);
}
