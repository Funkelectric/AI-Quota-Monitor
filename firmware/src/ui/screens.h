#pragma once
#include <Arduino.h>
#include "quota_state.h"

// netUp: WiFi connected. serialMode: showing USB-serial data path.
void drawOverview(const QuotaState &q, bool netUp, bool serialMode);
void drawProviders(const QuotaState &q, bool netUp, bool serialMode);
void drawScope(const QuotaState &q, bool netUp, bool serialMode);
void drawClock(const QuotaState &q, bool netUp, bool serialMode);
