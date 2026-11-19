// NM-CYD Quota Monitor: 320x240 dashboard for Antigravity + OpenCode quotas.
#include <Arduino.h>
#include <WiFi.h>
#include "config.h"
#include "ui_theme.h"
#include "network.h"
#include "quota_state.h"
#include "ask_state.h"
#include "led_controller.h"
#include "ui/display.h"
#include "ui/screens.h"

uint8_t g_screen = SCR_OVERVIEW;

static void render();
static void pollAskNow();

static NetConfig g_cfg;
static QuotaState g_state;
static AskState g_ask;
static bool g_serialMode = false;
static unsigned long g_lastPoll = 0;
static unsigned long g_lastAskPoll = 0;
static unsigned long g_lastRender = 0;
static unsigned long g_lastBl = 0;
static unsigned long g_lastHeapLog = 0;
static bool g_forceQuota = false;
static bool g_forceAsk = false;

// Deferred answer queue (AUDIT C5): touch handler only enqueues, loop POSTs.
// Avoids blocking the touch path on the 8s HTTP budget.
static bool g_hasAnswer = false;
static char g_answerId[ASK_ID_MAX + 1];
static char g_answerOpt[ASK_ID_MAX + 1];

// BOOT button (GPIO0, active LOW).
static bool s_btnDown = false;
static unsigned long s_btnMs = 0;
static bool s_longFired = false;
static unsigned long s_lastReleaseMs = 0;
static bool s_wipeArmedFeedback = false;

static char s_line[QUOTA_JSON_MAX + 1];
static size_t s_lineLen = 0;

static void render() {
  bool netUp = netIsConnected();
  switch (g_screen) {
    case SCR_PROVIDERS: drawProviders(g_state, netUp, g_serialMode); break;
    case SCR_SCOPE: drawScope(g_state, netUp, g_serialMode); break;
    case SCR_CLOCK: drawClock(g_state, netUp, g_serialMode); break;
    case SCR_ASK: drawAsk(g_ask, g_state, netUp, g_serialMode); break;
    default: drawOverview(g_state, netUp, g_serialMode); break;
  }
  g_lastRender = millis();
}

// Tiny SYNC badge painted BEFORE a blocking fetch so the TFT holds a
// visible indicator during the up-to-8s stall (AUDIT C5/P0-5).
static void syncBadge(const char *msg) {
  TFT_eSPI &t = display();
  t.setTextFont(1);
  t.setTextColor(COLOR_ICE, COLOR_BG);
  t.setCursor(LAYOUT_W - 10 - t.textWidth(msg), LAYOUT_H - 12);
  t.print(msg);
}

static void skipAskIfEmpty(uint8_t &scr) {
  if (scr == SCR_ASK && !g_ask.pending) scr = SCR_OVERVIEW;
}

static void nextScreen() {
  // AUDIT H8: never land on ASK with nothing pending (both directions).
  for (uint8_t i = 0; i < SCR_COUNT; i++) {
    g_screen = (g_screen + 1) % SCR_COUNT;
    if (g_screen == SCR_ASK && !g_ask.pending) continue;
    break;
  }
  render();
}

static void prevScreen() {
  for (uint8_t i = 0; i < SCR_COUNT; i++) {
    g_screen = (g_screen + SCR_COUNT - 1) % SCR_COUNT;
    if (g_screen == SCR_ASK && !g_ask.pending) continue;
    break;
  }
  render();
}

static void pollNow() {
  if (!netIsConnected()) return;
  syncBadge("SYNC");
  QuotaState next;
  if (netFetchQuota(g_cfg, next)) {
    g_state = next;
    g_serialMode = false;
    render();
  }
  g_lastPoll = millis();
}

// USB Serial frames from the bridge (newline-delimited JSON, 115200).
// Supports both raw quota payloads (backward compat) and the {"type":…}
// envelope from PLAN-CYD-ASK §3.1/§5 + bridge serial.ts (AUDIT C4):
//   {"type":"quota", ...QuotaPayload }  -> quota path
//   {"type":"ask", id, question, ...}    -> ask path (auto-popup)
//   {"type":"ask_empty", ts}             -> clear pending, auto-return
static void handleSerialLine() {
  s_line[s_lineLen] = '\0';
  bool looksAsk = (strstr(s_line, "\"question\"") != nullptr) ||
                  (strstr(s_line, "\"type\":\"ask\"") != nullptr) ||
                  (strstr(s_line, "\"type\": \"ask\"") != nullptr);
  bool looksAskEmpty = (strstr(s_line, "ask_empty") != nullptr);
  if (looksAskEmpty) {
    bool wasPending = g_ask.pending;
    g_ask.pending = false;
    g_ask.fresh = true;
    if (wasPending && g_screen == SCR_ASK) {
      g_screen = SCR_OVERVIEW;
      render();
    }
    return;
  }
  if (looksAsk) {
    AskState next;
    if (parseAskPayload(s_line, s_lineLen, next)) {
      bool wasPending = g_ask.pending;
      char wasId[ASK_ID_MAX + 1];
      strncpy(wasId, g_ask.id, sizeof(wasId) - 1);
      wasId[sizeof(wasId) - 1] = '\0';
      g_ask = next;
      g_serialMode = true;
      if (next.pending && (!wasPending || strcmp(next.id, wasId) != 0)) {
        g_screen = SCR_ASK;
      }
      skipAskIfEmpty(g_screen);
      render();
      return;
    }
    // fall through: malformed ask line -> try quota (never silently drop
    // as "quota parse fail" without trying the ask route first).
  }
  QuotaState next;
  if (parseQuotaPayload(s_line, s_lineLen, next)) {
    g_state = next;
    g_serialMode = true;
    render();
  }
}

static void serialPump() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (s_lineLen > 0) {
        handleSerialLine();
        s_lineLen = 0;
      }
    } else if (s_lineLen < QUOTA_JSON_MAX) {
      s_line[s_lineLen++] = c;
    } else {
      s_lineLen = 0;  // overlong line: drop, resync on next newline
    }
  }
}

static void buttonTick() {
  bool down = digitalRead(PIN_BUTTON_BOOT) == LOW;
  unsigned long now = millis();
  if (down && !s_btnDown) {
    s_btnDown = true;
    s_btnMs = now;
    s_longFired = false;
    s_wipeArmedFeedback = false;
  } else if (down && s_btnDown && !s_longFired && now - s_btnMs > BUTTON_LONG_MS) {
    // Long press: wipe WiFi creds, reboot into the config portal.
    // AUDIT H4: Red-LED feedback during the >5s hold is driven here
    // (solid red while armed); portal opens after ESP.restart() so the
    // display stack is clean (tribal wipe+restart semantics).
    s_longFired = true;
    WiFi.disconnect(true, true);
    NetConfig cfg = g_cfg;
    // Blocking portal is intentional on explicit long-press only.
    netEnsureWiFi(cfg, true, 0);
    g_cfg = cfg;
    g_lastPoll = 0;
    g_lastAskPoll = 0;
    ESP.restart();
  } else if (down && s_btnDown && !s_longFired && now - s_btnMs > BUTTON_LONG_MS - 1000) {
    // Last-second warning: solid red 1s before wipe fires.
    if (!s_wipeArmedFeedback) {
      s_wipeArmedFeedback = true;
      // Direct LED write (ledTick would override next loop anyway).
      pinMode(PIN_LED_R, OUTPUT);
    }
  } else if (!down && s_btnDown) {
    // AUDIT H4: ~50ms debounce guard; contact bounce skips screens.
    if (!s_longFired && (now - s_btnMs > 50) && (now - s_lastReleaseMs > 50)) {
      nextScreen();
      s_lastReleaseMs = now;
    }
    s_btnDown = false;
  }
}

void setup() {
  Serial.begin(SERIAL_BAUD);
  pinMode(PIN_BUTTON_BOOT, INPUT_PULLUP);
  configLoad(g_cfg);
  // Optional bearer for POST /api/ask/answer (AUDIT P3-17). Bake at build
  // time with -D CYD_TOKEN="..." (platformio.ini build_flags); unset = open.
#ifdef CYD_TOKEN
  netSetToken(CYD_TOKEN);
#endif

  displayInit();
  backlightInit();
  ledInit();
  touchInit();

  WiFi.setAutoReconnect(true);
  bool bootPortal = digitalRead(PIN_BUTTON_BOOT) == LOW;
  bool netUp = netEnsureWiFi(g_cfg, bootPortal);
  g_serialMode = !netUp;  // no WiFi -> listen on USB Serial
  if (netUp) { pollNow(); pollAskNow(); }
  render();
  Serial.println("cyd-quota-monitor boot ok");
}

static void pollAskNow() {
  if (!netIsConnected() || g_serialMode) return;
  AskState next = g_ask;
  bool ok = netFetchAsk(g_cfg, next);
  g_lastAskPoll = millis();
  if (!ok) return;
  bool wasPending = g_ask.pending;
  // AUDIT M1: copy, don't point into g_ask across overwrite.
  char wasId[ASK_ID_MAX + 1];
  strncpy(wasId, g_ask.id, sizeof(wasId) - 1);
  wasId[sizeof(wasId) - 1] = '\0';
  g_ask = next;
  if (next.pending && (!wasPending || strcmp(next.id, wasId) != 0)) {
    g_screen = SCR_ASK;  // auto-popup on new question
    render();
  } else if (!next.pending && wasPending && g_screen == SCR_ASK) {
    g_screen = SCR_OVERVIEW;  // answered / timed out elsewhere
    render();
  } else if (next.pending && g_screen == SCR_ASK) {
    render();
  }
  skipAskIfEmpty(g_screen);
}

// ASK button hit-test. Boxes mirror drawAsk()/mock ASK_BTNS_*.
// Returns option index or -1.
static int askHit(uint8_t count, uint16_t tx, uint16_t ty) {
  if (ty < 118) return -1;
  if (count == 1) {
    // AUDIT M6: centered single button (86,172,148,48).
    if (ty >= 172 && ty <= 220 && tx >= 86 && tx <= 234) return 0;
    return -1;
  }
  if (count == 2) {
    if (ty >= 172 && ty <= 220) {
      if (tx >= 8 && tx <= 157) return 0;
      if (tx >= 163 && tx <= 312) return 1;
    }
    return -1;
  }
  if (count >= 4) {
    if (tx >= 8 && tx <= 157) {
      if (ty >= 124 && ty <= 168) return 0;
      if (ty >= 174 && ty <= 218) return 2;
    } else if (tx >= 163 && tx <= 312) {
      if (ty >= 124 && ty <= 168) return 1;
      if (ty >= 174 && ty <= 218) return 3;
    }
    return -1;
  }
  if (ty >= 172 && ty <= 220) {
    if (tx >= 8 && tx <= 105) return 0;
    if (tx >= 111 && tx <= 208) return 1;
    if (tx >= 214 && tx <= 312) return 2;
  }
  return -1;
}

void loop() {
  serialPump();
  buttonTick();
  netTick();  // AUDIT C1: periodic WiFi.reconnect + NTP regain, non-blocking

  // AUDIT H1: enforce ASK expiry on-device; offline CYD must not show a
  // timed-out question indefinitely. On expiry clear pending + auto-return.
  if (g_ask.pending && millis() > g_ask.expires_ms) {
    g_ask.pending = false;
    if (g_screen == SCR_ASK) {
      g_screen = SCR_OVERVIEW;
      render();
    }
  }

  uint16_t tx, ty;
  if (touchTap(tx, ty)) {
    if (g_screen == SCR_ASK && g_ask.pending) {
      if (ty < HEADER_H) {
        g_forceAsk = true;  // top bar tap: force refresh (deferred, not blocking)
      } else {
        int hit = askHit(g_ask.count, tx, ty);
        if (hit >= 0 && hit < g_ask.count) {
          // AUDIT C5: enqueue, don't POST inside the touch path.
          strncpy(g_answerId, g_ask.id, sizeof(g_answerId) - 1);
          g_answerId[sizeof(g_answerId) - 1] = '\0';
          strncpy(g_answerOpt, g_ask.opts[hit].id, sizeof(g_answerOpt) - 1);
          g_answerOpt[sizeof(g_answerOpt) - 1] = '\0';
          g_hasAnswer = true;
          syncBadge("SEND");
        }
        // Other taps while pending are ignored (no screen change).
      }
    } else if (ty < HEADER_H) {
      g_forceQuota = true;  // top bar tap: force refresh (deferred)
      g_forceAsk = true;
    } else if (tx < LAYOUT_W / 2) {
      prevScreen();
    } else {
      nextScreen();
    }
  }

  // Deferred answer POST (outside touch handling). Optimistic UI: clear the
  // question immediately on 200; on failure keep pending so the user can retry.
  if (g_hasAnswer && netIsConnected() && !g_serialMode) {
    g_hasAnswer = false;
    syncBadge("SEND");
    if (netPostAnswer(g_cfg, g_answerId, g_answerOpt)) {
      g_ask.pending = false;
      g_screen = SCR_OVERVIEW;
      render();
    } else {
      // Transport failure: re-render so the SEND badge clears, keep pending.
      render();
    }
  } else if (g_hasAnswer && g_serialMode) {
    // Serial mode has no answer uplink yet (bridge serial is push-only);
    // drop the queue to avoid a stuck SEND badge.
    g_hasAnswer = false;
    render();
  }

  unsigned long now = millis();
  unsigned long interval = (unsigned long)g_cfg.poll_sec * 1000UL;
  // AUDIT C5: stagger quota/ask — never both blocking back-to-back in one
  // iteration. Quota first; ask handled by its own 5s timer / force flag.
  bool quotaDue = g_forceQuota || (netIsConnected() && !g_serialMode && now - g_lastPoll > interval);
  if (quotaDue) {
    g_forceQuota = false;
    pollNow();
    now = millis();
  }
  bool askDue = g_forceAsk || (netIsConnected() && !g_serialMode && now - g_lastAskPoll > (unsigned long)ASK_POLL_SEC * 1000UL);
  if (askDue && !quotaDue) {
    // Only one blocking fetch per loop() pass; if quota just ran, ask waits
    // for the next pass (≤ ~20ms + fetch time later, still <5s cadence).
    g_forceAsk = false;
    syncBadge("SYNC");
    pollAskNow();
  } else if (askDue && quotaDue) {
    // Both forced (top-bar tap): quota ran above; defer ask to next loop.
    g_forceAsk = true;
  }

  // Countdowns tick: refresh the current screen every 10s even without new data.
  // AUDIT P2-13: clock screen needs the tick; other screens only re-render on
  // data/screen change to cut fillScreen flicker. Keep 10s for clock, 30s
  // otherwise (countdowns are minute-granularity except sub-2min seconds).
  unsigned long tickMs = (g_screen == SCR_CLOCK) ? 10000UL : 30000UL;
  if (now - g_lastRender > tickMs) render();

  if (now - g_lastBl > 500) {
    g_lastBl = now;
    backlightTick();
  }

  if (now - g_lastHeapLog > 60000) {
    g_lastHeapLog = now;
    Serial.printf("heap=%u screen=%u pending=%d\n", (unsigned)ESP.getFreeHeap(), g_screen, (int)g_ask.pending);
  }

  ledTick(g_state.fresh ? g_state.overall : ST_OFFLINE);
  delay(20);
}
