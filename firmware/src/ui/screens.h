#pragma once
#include <Arduino.h>
#include "quota_state.h"
#include "ask_state.h"

// netUp: WiFi connected. serialMode: showing USB-serial data path.
void drawOverview(const QuotaState &q, bool netUp, bool serialMode);
void drawProviders(const QuotaState &q, bool netUp, bool serialMode);
void drawScope(const QuotaState &q, bool netUp, bool serialMode);
void drawClock(const QuotaState &q, bool netUp, bool serialMode);
void drawAsk(const AskState &a, const QuotaState &q, bool netUp, bool serialMode);
// END - WORK latch: hero blinks TEXT white <-> ICE blue each poll (blinkBlue).
// CYD only (TV154 never enters SCR_ENDWORK).
void drawEndWork(const QuotaState &q, bool netUp, bool serialMode, bool blinkBlue);
