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
// END latch: WORK hero blinks TEXT white <-> ICE blue each poll (blinkBlue);
// TASK (agents still running) holds solid ICE so the two states differ at a
// glance. Shared by CYD (320) and TV154 (240); TASK subline is part of the
// centered block (see drawEndWork).
void drawEndWork(const QuotaState &q, bool netUp, bool serialMode, bool blinkBlue);
