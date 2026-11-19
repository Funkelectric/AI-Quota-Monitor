#pragma once
#include <Arduino.h>
#include "config.h"

// Pending OpenCode question for the 05 ASK screen (GET /api/ask).
struct AskOpt {
  char id[ASK_ID_MAX + 1];
  char label[ASK_OPT_LABEL_MAX + 1];
};

struct AskState {
  char id[ASK_ID_MAX + 1];
  char question[ASK_QUESTION_MAX + 1];
  char detail[ASK_DETAIL_MAX + 1];
  AskOpt opts[ASK_OPTS_MAX];
  uint8_t count;
  unsigned long expires_ms;
  bool pending;
  bool fresh;  // true once we have seen at least one payload (pending or 204)
};

/** Parse a GET /api/ask body (200). False on parse error (out untouched). */
bool parseAskPayload(const char *json, size_t len, AskState &out);
