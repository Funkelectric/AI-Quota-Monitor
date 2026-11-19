#pragma once
#include <Arduino.h>
#include "config.h"

void ledInit();
// status: ST_OK / ST_WARN / ST_CRIT / ST_OFFLINE. Call every loop for blink.
void ledTick(uint8_t status);

void backlightInit();
// LDR-following brightness 20..255. Call every ~500ms.
void backlightTick();
void backlightSet(uint8_t duty);
