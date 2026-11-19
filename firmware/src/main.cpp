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
static bool g_forcePoll = false;

// BOOT button (GPIO0, active LOW).
static bool s_btnDown = false;
static unsigned long s_btnMs = 0;
static bool s_longFired = false;

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

static void nextScreen() {
  g_screen = (g_screen + 1) % SCR_COUNT;
  render();
}

static void prevScreen() {
  g_screen = (g_screen + SCR_COUNT - 1) % SCR_COUNT;
  render();
}

static void pollNow() {
  if (!netIsConnected()) return;
  QuotaState next;
  if (netFetchQuota(g_cfg, next)) {
    g_state = next;
    g_serialMode = false;
    render();
  }
  g_lastPoll = millis();
}

// USB Serial frames from the bridge (newline-delimited JSON, 115200).
static void serialPump() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (s_lineLen > 0) {
        QuotaState next;
        if (parseQuotaPayload(s_line, s_lineLen, next)) {
          g_state = next;
          g_serialMode = true;
          render();
        }
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
  } else if (down && s_btnDown && !s_longFired && now - s_btnMs > BUTTON_LONG_MS) {
    // Long press: wipe WiFi creds, reboot into the config portal.
    s_longFired = true;
    WiFi.disconnect(true, true);
    NetConfig cfg = g_cfg;
    netEnsureWiFi(cfg, true, 0);
    g_cfg = cfg;
    g_lastPoll = 0;
  } else if (!down && s_btnDown) {
    if (!s_longFired) nextScreen();
    s_btnDown = false;
  }
}

void setup() {
  Serial.begin(SERIAL_BAUD);
  pinMode(PIN_BUTTON_BOOT, INPUT_PULLUP);
  configLoad(g_cfg);

  displayInit();
  backlightInit();
  ledInit();
  touchInit();

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
  const char *wasId = g_ask.id;
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
}

// ASK button hit-test. Boxes mirror drawAsk()/mock ASK_BTNS_*.
// Returns option index or -1.
static int askHit(uint8_t count, uint16_t tx, uint16_t ty) {
  if (ty < 118) return -1;
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

  uint16_t tx, ty;
  if (touchTap(tx, ty)) {
    if (g_screen == SCR_ASK && g_ask.pending) {
      if (ty < HEADER_H) {
        g_forcePoll = true;  // top bar tap: force refresh
        pollAskNow();
      } else {
        int hit = askHit(g_ask.count, tx, ty);
        if (hit >= 0 && hit < g_ask.count) {
          if (netPostAnswer(g_cfg, g_ask.id, g_ask.opts[hit].id)) {
            g_ask.pending = false;
            g_screen = SCR_OVERVIEW;
            render();
          }
        }
        // Other taps while pending are ignored (no screen change).
      }
    } else if (ty < HEADER_H) {
      g_forcePoll = true;  // top bar tap: force refresh
    } else if (tx < LAYOUT_W / 2) {
      prevScreen();
    } else {
      nextScreen();
    }
  }

  unsigned long now = millis();
  unsigned long interval = (unsigned long)g_cfg.poll_sec * 1000UL;
  if (g_forcePoll || (netIsConnected() && !g_serialMode && now - g_lastPoll > interval)) {
    g_forcePoll = false;
    pollNow();
    pollAskNow();
  }
  if (netIsConnected() && !g_serialMode && now - g_lastAskPoll > (unsigned long)ASK_POLL_SEC * 1000UL) {
    pollAskNow();
  }

  // Countdowns tick: refresh the current screen every 10s even without new data.
  if (now - g_lastRender > 10000) render();

  if (now - g_lastBl > 500) {
    g_lastBl = now;
    backlightTick();
  }

  ledTick(g_state.fresh ? g_state.overall : ST_OFFLINE);
  delay(20);
}
