#include "quota_state.h"
#include <ArduinoJson.h>
#include <string.h>

uint8_t statusForPct(float pct) {
  if (pct < QUOTA_WARN_MIN) return ST_CRIT;
  if (pct < QUOTA_OK_MIN) return ST_WARN;
  return ST_OK;
}

void fmtCountdown(long sec, char *out, size_t outLen) {
  if (sec < 0) sec = 0;
  if (sec < 3600) {
    snprintf(out, outLen, "%ldm", sec / 60);
  } else if (sec < 86400) {
    snprintf(out, outLen, "%ldh %ldm", sec / 3600, (sec % 3600) / 60);
  } else {
    snprintf(out, outLen, "%ldd %ldh", sec / 86400, (sec % 86400) / 3600);
  }
}

float minRemaining(const QuotaState &q) {
  if (q.oc_count == 0) return 100.0f;
  float m = 100.0f;
  for (uint8_t i = 0; i < q.oc_count; i++) m = min(m, q.oc[i].remaining_pct);
  return m;
}

long minReset(const QuotaState &q) {
  if (q.oc_count == 0) return 0;
  long m = q.oc[0].reset_in_sec;
  for (uint8_t i = 0; i < q.oc_count; i++) m = min(m, q.oc[i].reset_in_sec);
  return m;
}

static void copyName(char *dst, size_t dstLen, const char *src) {
  if (!src) src = "?";
  strncpy(dst, src, dstLen - 1);
  dst[dstLen - 1] = '\0';
}

static uint8_t parseStatus(const char *s, float pct) {
  if (s) {
    if (strcmp(s, "crit") == 0) return ST_CRIT;
    if (strcmp(s, "warn") == 0) return ST_WARN;
    if (strcmp(s, "ok") == 0) return ST_OK;
  }
  return statusForPct(pct);
}

// Reused document: one allocation, cleared per parse (heap-stable for soak).
static JsonDocument g_doc;

bool parseQuotaPayload(const char *json, size_t len, QuotaState &out) {
  if (!json || len == 0 || len > QUOTA_JSON_MAX) return false;
  g_doc.clear();
  DeserializationError err = deserializeJson(g_doc, json, len);
  if (err) return false;

  QuotaState next = {};
  next.updated_ms = millis();

  // overall
  const char *overall = g_doc["overall_status"] | "offline";
  if (strcmp(overall, "ok") == 0) next.overall = ST_OK;
  else if (strcmp(overall, "warn") == 0) next.overall = ST_WARN;
  else if (strcmp(overall, "crit") == 0) next.overall = ST_CRIT;
  else next.overall = ST_OFFLINE;

  // opencode block
  JsonObject oc = g_doc["opencode"];
  next.oc_connected = oc["connected"] | false;
  next.oc_cost = oc["today_cost_usd"] | 0.0f;
  next.oc_tokens_k = oc["today_tokens_k"] | 0.0f;
  next.oc_stale = oc["stale"] | false;
  JsonArray provs = oc["providers"];
  next.oc_count = 0;
  if (!provs.isNull()) {
    for (JsonObject p : provs) {
      if (next.oc_count >= POOLS_MAX) break;
      PoolState &dst = next.oc[next.oc_count++];
      copyName(dst.name, sizeof(dst.name), p["name"] | "?");
      dst.remaining_pct = p["remaining_pct"] | 0.0f;
      dst.reset_in_sec = p["reset_in_sec"] | 0L;
      dst.status = parseStatus(p["status"], dst.remaining_pct);
    }
  }
  JsonArray sess = oc["sessions"];
  next.session_count = 0;
  if (!sess.isNull()) {
    for (JsonObject s : sess) {
      if (next.session_count >= SESSIONS_MAX) break;
      SessionState &d = next.sessions[next.session_count++];
      copyName(d.title, sizeof(d.title), s["title"] | "?");
      copyName(d.model, sizeof(d.model), s["model"] | "?");
    }
  }

  // Recompute overall locally so a stale/missing field can't lie to the LED.
  if (!next.oc_connected) {
    next.overall = ST_OFFLINE;
  } else {
    uint8_t worst = ST_OK;
    for (uint8_t i = 0; i < next.oc_count; i++) worst = max(worst, next.oc[i].status);
    next.overall = worst;
  }

  next.fresh = true;
  out = next;
  return true;
}
