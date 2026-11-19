#pragma once
#include <Arduino.h>
#include "config.h"

// Parsed snapshot of GET /api/quota (or the USB Serial line). OpenCode only.
struct PoolState {
  char name[POOL_NAME_MAX + 1];
  float remaining_pct;
  long reset_in_sec;
  uint8_t status;  // ST_OK / ST_WARN / ST_CRIT
};

struct SessionState {
  char title[SESSION_TITLE_MAX + 1];
  char model[SESSION_MODEL_MAX + 1];
};

struct QuotaState {
  bool oc_connected;
  float oc_cost;
  float oc_tokens_k;
  PoolState oc[POOLS_MAX];
  uint8_t oc_count;
  bool oc_stale;
  SessionState sessions[SESSIONS_MAX];
  uint8_t session_count;

  uint8_t overall;  // ST_OK / ST_WARN / ST_CRIT / ST_OFFLINE
  unsigned long updated_ms;
  bool fresh;  // false until the first successful parse
};

/** Parse a JSON payload buffer (not necessarily NUL-terminated, len bytes). */
bool parseQuotaPayload(const char *json, size_t len, QuotaState &out);

/** Human countdown: 90 -> "1m", 5400 -> "1h 30m", 90000 -> "25h 0m". */
void fmtCountdown(long sec, char *out, size_t outLen);

/** Map remaining% to ST_* using QUOTA_OK_MIN / QUOTA_WARN_MIN. */
uint8_t statusForPct(float pct);

/** Minimum remaining% across providers (100 when none). */
float minRemaining(const QuotaState &q);

/** Shortest reset across providers in seconds (0 when none). */
long minReset(const QuotaState &q);
