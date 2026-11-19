#include "ask_state.h"
#include <ArduinoJson.h>
#include <string.h>

static void copyAsk(char *dst, size_t dstLen, const char *src) {
  if (!src) src = "?";
  strncpy(dst, src, dstLen - 1);
  dst[dstLen - 1] = '\0';
}

// Own static doc: never shares quota_state's document (heap-stable for soak).
static JsonDocument g_askDoc;

bool parseAskPayload(const char *json, size_t len, AskState &out) {
  if (!json || len == 0 || len > ASK_JSON_MAX) return false;
  g_askDoc.clear();
  DeserializationError err = deserializeJson(g_askDoc, json, len);
  if (err) return false;

  AskState next = {};
  next.pending = true;
  next.fresh = true;
  copyAsk(next.id, sizeof(next.id), g_askDoc["id"] | "");
  if (strlen(next.id) == 0) return false;
  copyAsk(next.question, sizeof(next.question), g_askDoc["question"] | "?");
  copyAsk(next.detail, sizeof(next.detail), g_askDoc["detail"] | "");
  long timeout_sec = g_askDoc["timeout_sec"] | 90L;
  if (timeout_sec < 10) timeout_sec = 10;
  if (timeout_sec > 300) timeout_sec = 300;
  long ts = g_askDoc["ts"] | 0L;
  (void)ts;
  next.expires_ms = millis() + (unsigned long)timeout_sec * 1000UL;
  JsonArray opts = g_askDoc["options"];
  next.count = 0;
  if (!opts.isNull()) {
    for (JsonObject o : opts) {
      if (next.count >= ASK_OPTS_MAX) break;
      AskOpt &d = next.opts[next.count++];
      copyAsk(d.id, sizeof(d.id), o["id"] | "");
      copyAsk(d.label, sizeof(d.label), o["label"] | "?");
      if (strlen(d.id) == 0) snprintf(d.id, sizeof(d.id), "opt%d", next.count);
    }
  }
  if (next.count == 0) return false;
  out = next;
  return true;
}
