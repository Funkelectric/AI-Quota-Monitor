#!/usr/bin/env bash
# NM-CYD Quota Monitor: sync firmware sources, build, flash.
# Usage: flash-cyd.sh [cyd-st7789|cyd-ili9341]  (default: cyd-st7789)
# White/inverted screen after flashing => re-run with cyd-ili9341.
set -euo pipefail

ENV="${1:-cyd-st7789}"
PORT="${PORT:-/dev/ttyUSB0}"
export PATH="$HOME/.local/bin:$PATH"

command -v pio >/dev/null || { echo "ERROR: platformio not found. Install with:"; echo "  sudo apt install -y python3-pip && pip install --user platformio --break-system-packages"; exit 1; }

FW=~/cyd-quota-monitor/firmware
mkdir -p "$FW/include" "$FW/src/ui"
cd "$FW"

cat > platformio.ini <<'EOF_INI'
; NM-CYD Quota Monitor firmware (ESP32-2432S028R)
; TFT configured purely via build_flags (USER_SETUP_LOADED) so no manual
; User_Setup.h editing is needed. Two display revisions supported.

[platformio]
default_envs = cyd-st7789

[env:cyd-st7789]
platform = espressif32
board = esp32dev
framework = arduino
board_build.partitions = huge_app.csv
monitor_speed = 115200
build_flags =
  -D USER_SETUP_LOADED=1
  -D ST7789_DRIVER=1
  -D TFT_WIDTH=240
  -D TFT_HEIGHT=320
  -D TFT_MOSI=13
  -D TFT_MISO=12
  -D TFT_SCLK=14
  -D TFT_CS=15
  -D TFT_DC=2
  -D TFT_RST=-1
  -D TFT_BL=21
  -D TFT_BACKLIGHT_ON=1
  -D SPI_FREQUENCY=40000000
  -D LOAD_GLCD=1
  -D LOAD_FONT2=1
  -D LOAD_FONT4=1
  -D LOAD_FONT6=1
  -D LOAD_FONT7=1
  -D LOAD_FONT8=1
  -D CYD_ST7789=1
  -D TFT_INVERSION_ON=1
lib_deps =
  bodmer/TFT_eSPI@^2.5.43
  bblanchon/ArduinoJson@^7.0.4
  tzapu/WiFiManager@^2.0.17
  https://github.com/PaulStoffregen/XPT2046_Touchscreen.git

[env:cyd-ili9341]
extends = env:cyd-st7789
build_flags =
  -D USER_SETUP_LOADED=1
  -D ILI9341_DRIVER=1
  -D TFT_WIDTH=240
  -D TFT_HEIGHT=320
  -D TFT_MOSI=13
  -D TFT_MISO=12
  -D TFT_SCLK=14
  -D TFT_CS=15
  -D TFT_DC=2
  -D TFT_RST=-1
  -D TFT_BL=21
  -D TFT_BACKLIGHT_ON=1
  -D SPI_FREQUENCY=40000000
  -D LOAD_GLCD=1
  -D LOAD_FONT2=1
  -D LOAD_FONT4=1
  -D LOAD_FONT6=1
  -D LOAD_FONT7=1
  -D LOAD_FONT8=1
  -D CYD_ILI9341_DRIVER=1
EOF_INI

cat > include/config.h <<'EOF_CFG'
#pragma once

// Pin map for ESP32-2432S028R (NM-CYD), landscape 320x240.
#define PIN_TFT_MOSI 13
#define PIN_TFT_MISO 12
#define PIN_TFT_SCLK 14
#define PIN_TFT_CS   15
#define PIN_TFT_DC    2
#define PIN_TFT_RST  -1
#define PIN_TFT_BL   21

// XPT2046 touch on dedicated SPI bus (do NOT share TFT bus).
#define PIN_TOUCH_CLK  25
#define PIN_TOUCH_MOSI 32
#define PIN_TOUCH_MISO 39
#define PIN_TOUCH_CS   33
#define PIN_TOUCH_IRQ  36

// Touch raw calibration (XPT2046, fixed raw frame; firmware flips for rotation).
// Halves are generous so these only need to be approximately right.
#define TOUCH_RAW_X_MIN 240
#define TOUCH_RAW_X_MAX 3800
#define TOUCH_RAW_Y_MIN 240
#define TOUCH_RAW_Y_MAX 3800

// Common-anode RGB LED (active LOW): 255=OFF, 0=full brightness.
#define PIN_LED_R  4
#define PIN_LED_G 16
#define PIN_LED_B 17

#define PIN_LDR       34
#define PIN_BUTTON_BOOT 0

// Thresholds mirror bridge/types.ts
#define QUOTA_OK_MIN   50
#define QUOTA_WARN_MIN 20

// Status codes shared by LED + UI.
#define ST_OK      0
#define ST_WARN    1
#define ST_CRIT    2
#define ST_OFFLINE 3

// Screens
#define SCR_OVERVIEW  0
#define SCR_PROVIDERS 1
#define SCR_SCOPE     2
#define SCR_CLOCK     3
#define SCR_COUNT     4

// Network / bridge defaults
#define WIFI_AP_NAME "NM-Quota-Setup"
#define BRIDGE_HOST_DEFAULT "quota-bridge.local"
#define BRIDGE_PORT_DEFAULT 3847
#define POLL_INTERVAL_SEC_DEFAULT 15
#define HTTP_TIMEOUT_MS 8000
#define SERIAL_BAUD 115200

// NTP (clock screen). CET/CEST default; change to taste.
#define NTP_TZ "CET-1CEST,M3.5.0,M10.5.0/3"
#define NTP_SERVER_1 "pool.ntp.org"
#define NTP_SERVER_2 "time.nist.gov"

// NVS namespace + keys
#define NVS_NS "quota-mon"
#define NVS_KEY_HOST "br_host"
#define NVS_KEY_PORT "br_port"
#define NVS_KEY_POLL "poll_sec"

// Long-press duration that wipes WiFi creds + opens the portal.
#define BUTTON_LONG_MS 5000

// Compact payload guard: ESP32 parses this on the stack.
#define QUOTA_JSON_MAX 2048
#define POOL_NAME_MAX 23
#define MODEL_NAME_MAX 23
#define POOLS_MAX 4
EOF_CFG

cat > include/ui_theme.h <<'EOF_THEME'
#pragma once
#include <stdint.h>

// Dark dashboard palette: exact RGB565 truncations of the hex targets.
#define COLOR_BG        0x1082  // #0D1117
#define COLOR_CARD      0x10C4  // #161B22
#define COLOR_TEXT      0xFFFF
#define COLOR_DIM       0x8CB3  // #8B949E
#define COLOR_GREEN     0x3DCA  // #3FB950
#define COLOR_AMBER     0xD4C4  // #D29922
#define COLOR_RED       0xFA89  // #F85149
#define COLOR_BLUE      0x2D9D  // info / offline accent
#define COLOR_ICE       0x7EBF  // ice-blue accent (#7FD4FF)
#define COLOR_EDGE      0x2988  // hairline borders (#2A3340)
#define COLOR_GRID      0x1906  // faint panel grid (#1B2230)
#define COLOR_WAVE_TOP  0x2AD1  // quota area top (#2A5A8C)

// Display rotation: 3 = landscape 180° (USB port on the LEFT).
// 1 = landscape (USB on the right). Touch mapping flips to match.
#define DISPLAY_ROTATION 3

// Layout (landscape 320x240).
#define LAYOUT_W        320
#define LAYOUT_H        240
#define HEADER_H        28
#define MARGIN          8
#define CARD_R          6

// Status -> color helper (implemented in screens.cpp).
uint16_t statusColor(uint8_t status);
EOF_THEME

cat > src/network.h <<'EOF_NETH'
#pragma once
#include <Arduino.h>
#include "config.h"

struct NetConfig {
  char host[64];
  uint16_t port;
  uint16_t poll_sec;
};

void configLoad(NetConfig &cfg);
void configSave(const NetConfig &cfg);

/**
 * Bring up WiFi. Returns true when connected.
 * Opens the NM-Quota-Setup captive portal when no credentials are stored
 * (portalTimeoutMs) or when forcePortal is true (BOOT long-press path).
 */
bool netEnsureWiFi(NetConfig &cfg, bool forcePortal, unsigned long portalTimeoutMs = 180000);

/** GET http://host:port/api/quota into out. False on any transport/parse error. */
bool netFetchQuota(const NetConfig &cfg, struct QuotaState &out);

bool netIsConnected();
EOF_NETH

cat > src/quota_state.h <<'EOF_QSH'
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

struct QuotaState {
  bool oc_connected;
  float oc_cost;
  float oc_tokens_k;
  PoolState oc[POOLS_MAX];
  uint8_t oc_count;
  bool oc_stale;

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
EOF_QSH

cat > src/led_controller.h <<'EOF_LEDH'
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
EOF_LEDH

cat > src/ui/display.h <<'EOF_DISPH'
#pragma once
#include <Arduino.h>
#include <TFT_eSPI.h>

void displayInit();
TFT_eSPI &display();

void touchInit();
// Returns true on a fresh tap with mapped screen coords.
bool touchTap(uint16_t &x, uint16_t &y);
EOF_DISPH

cat > src/ui/screens.h <<'EOF_SCRH'
#pragma once
#include <Arduino.h>
#include "quota_state.h"

// netUp: WiFi connected. serialMode: showing USB-serial data path.
void drawOverview(const QuotaState &q, bool netUp, bool serialMode);
void drawProviders(const QuotaState &q, bool netUp, bool serialMode);
void drawScope(const QuotaState &q, bool netUp, bool serialMode);
void drawClock(const QuotaState &q, bool netUp, bool serialMode);
EOF_SCRH

cat > src/quota_state.cpp <<'EOF_QS'
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
EOF_QS

cat > src/led_controller.cpp <<'EOF_LED'
#include "led_controller.h"

// Active-LOW common-anode LED: analogWrite(pin, 255) = OFF.
static void ledWrite(uint8_t pin, uint8_t brightness) {
  analogWrite(pin, 255 - brightness);
}

void ledInit() {
  pinMode(PIN_LED_R, OUTPUT);
  pinMode(PIN_LED_G, OUTPUT);
  pinMode(PIN_LED_B, OUTPUT);
  ledWrite(PIN_LED_R, 0);
  ledWrite(PIN_LED_G, 0);
  ledWrite(PIN_LED_B, 0);
}

void ledTick(uint8_t status) {
  unsigned long now = millis();
  switch (status) {
    case ST_OK:
      ledWrite(PIN_LED_R, 0);
      ledWrite(PIN_LED_G, 140);
      ledWrite(PIN_LED_B, 0);
      break;
    case ST_WARN:
      ledWrite(PIN_LED_R, 160);
      ledWrite(PIN_LED_G, 90);
      ledWrite(PIN_LED_B, 0);
      break;
    case ST_CRIT:
      // Breathing red alert.
      if ((now / 500) % 2 == 0) {
        ledWrite(PIN_LED_R, 200);
        ledWrite(PIN_LED_G, 0);
        ledWrite(PIN_LED_B, 0);
      } else {
        ledWrite(PIN_LED_R, 0);
        ledWrite(PIN_LED_G, 0);
        ledWrite(PIN_LED_B, 0);
      }
      break;
    default:  // ST_OFFLINE: slow dim-blue pulse.
      if ((now / 1000) % 2 == 0) {
        ledWrite(PIN_LED_R, 0);
        ledWrite(PIN_LED_G, 0);
        ledWrite(PIN_LED_B, 40);
      } else {
        ledWrite(PIN_LED_R, 0);
        ledWrite(PIN_LED_G, 0);
        ledWrite(PIN_LED_B, 0);
      }
      break;
  }
}

static uint8_t g_bl = 255;

void backlightInit() {
  pinMode(PIN_TFT_BL, OUTPUT);
  analogWrite(PIN_TFT_BL, g_bl);
}

void backlightSet(uint8_t duty) {
  g_bl = duty;
  analogWrite(PIN_TFT_BL, duty);
}

void backlightTick() {
  // LDR on GPIO34: brighter room -> higher ADC -> brighter backlight.
  // Clamp to a readable floor so the screen never goes fully dark.
  int raw = analogRead(PIN_LDR);
  uint8_t target = (uint8_t)constrain(map(raw, 200, 3500, 40, 255), 40, 255);
  // Ease toward target to avoid flicker on noisy readings.
  if (target > g_bl) g_bl++;
  else if (target < g_bl) g_bl--;
  analogWrite(PIN_TFT_BL, g_bl);
}
EOF_LED

cat > src/network.cpp <<'EOF_NET'
#include "network.h"
#include "quota_state.h"
#include <HTTPClient.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <string.h>
#include <time.h>

void configLoad(NetConfig &cfg) {
  strncpy(cfg.host, BRIDGE_HOST_DEFAULT, sizeof(cfg.host) - 1);
  cfg.host[sizeof(cfg.host) - 1] = '\0';
  cfg.port = BRIDGE_PORT_DEFAULT;
  cfg.poll_sec = POLL_INTERVAL_SEC_DEFAULT;

  Preferences p;
  if (!p.begin(NVS_NS, true)) return;
  String h = p.getString(NVS_KEY_HOST, cfg.host);
  strncpy(cfg.host, h.c_str(), sizeof(cfg.host) - 1);
  cfg.port = p.getUShort(NVS_KEY_PORT, cfg.port);
  cfg.poll_sec = p.getUShort(NVS_KEY_POLL, cfg.poll_sec);
  if (cfg.poll_sec < 5) cfg.poll_sec = 5;
  if (cfg.poll_sec > 300) cfg.poll_sec = 300;
  p.end();
}

void configSave(const NetConfig &cfg) {
  Preferences p;
  if (!p.begin(NVS_NS, false)) return;
  p.putString(NVS_KEY_HOST, cfg.host);
  p.putUShort(NVS_KEY_PORT, cfg.port);
  p.putUShort(NVS_KEY_POLL, cfg.poll_sec);
  p.end();
}

static char g_host[64];
static char g_port[8];
static char g_poll[8];
static bool g_save = false;

static void saveParamsCallback() { g_save = true; }

bool netEnsureWiFi(NetConfig &cfg, bool forcePortal, unsigned long portalTimeoutMs) {
  if (WiFi.status() == WL_CONNECTED && !forcePortal) return true;

  WiFi.mode(WIFI_STA);
  WiFiManager wm;
  wm.setTitle("NM Quota Monitor");
  wm.setConfigPortalTimeout(portalTimeoutMs / 1000);

  snprintf(g_host, sizeof(g_host), "%s", cfg.host);
  snprintf(g_port, sizeof(g_port), "%u", cfg.port);
  snprintf(g_poll, sizeof(g_poll), "%u", cfg.poll_sec);

  WiFiManagerParameter p_host("br_host", "Bridge host", g_host, sizeof(g_host));
  WiFiManagerParameter p_port("br_port", "Bridge port", g_port, sizeof(g_port));
  WiFiManagerParameter p_poll("poll_sec", "Poll interval (s)", g_poll, sizeof(g_poll));
  wm.addParameter(&p_host);
  wm.addParameter(&p_port);
  wm.addParameter(&p_poll);
  wm.setSaveParamsCallback(saveParamsCallback);

  bool ok;
  if (forcePortal) {
    wm.setConfigPortalTimeout(0);  // stay open until configured
    ok = wm.startConfigPortal(WIFI_AP_NAME);
  } else {
    ok = wm.autoConnect(WIFI_AP_NAME);
  }

  if (ok) {
    strncpy(cfg.host, p_host.getValue(), sizeof(cfg.host) - 1);
    cfg.port = (uint16_t)atoi(p_port.getValue());
    cfg.poll_sec = (uint16_t)atoi(p_poll.getValue());
    if (cfg.port == 0) cfg.port = BRIDGE_PORT_DEFAULT;
    if (cfg.poll_sec < 5 || cfg.poll_sec > 300) cfg.poll_sec = POLL_INTERVAL_SEC_DEFAULT;
    if (g_save) {
      configSave(cfg);
      g_save = false;
    }
    // NTP for the header/clock screen (best effort).
    configTzTime(NTP_TZ, NTP_SERVER_1, NTP_SERVER_2);
  }
  return ok && WiFi.status() == WL_CONNECTED;
}

// Shared fetch buffer: single static allocation, reused every poll.
static char g_buf[QUOTA_JSON_MAX + 1];

bool netFetchQuota(const NetConfig &cfg, QuotaState &out) {
  if (WiFi.status() != WL_CONNECTED) return false;
  char url[128];
  snprintf(url, sizeof(url), "http://%s:%u/api/quota", cfg.host, cfg.port);

  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
  if (!http.begin(url)) return false;
  int code = http.GET();
  bool ok = false;
  if (code == 200) {
    int len = http.getSize();
    if (len < 0) len = QUOTA_JSON_MAX;
    if (len > QUOTA_JSON_MAX) len = QUOTA_JSON_MAX;
    WiFiClient *stream = http.getStreamPtr();
    size_t n = 0;
    unsigned long deadline = millis() + HTTP_TIMEOUT_MS;
    unsigned long lastProgress = millis();
    while (n < (size_t)len && millis() < deadline) {
      while (stream->available() && n < QUOTA_JSON_MAX) {
        g_buf[n++] = (char)stream->read();
        lastProgress = millis();
      }
      if ((int)n >= len && len > 0) break;
      if (millis() - lastProgress > 1500) break;  // stalled body: parse what we have
      delay(1);
    }
    ok = parseQuotaPayload(g_buf, n, out);
  }
  http.end();
  return ok;
}

bool netIsConnected() { return WiFi.status() == WL_CONNECTED; }
EOF_NET

cat > src/ui/display.cpp <<'EOF_DISP'
#include "display.h"
#include <SPI.h>
#include <XPT2046_Touchscreen.h>
#include "config.h"
#include "ui_theme.h"

static TFT_eSPI g_tft;
static SPIClass g_touchSPI(VSPI);
static XPT2046_Touchscreen g_touch(PIN_TOUCH_CS, PIN_TOUCH_IRQ);

void displayInit() {
  g_tft.init();
  g_tft.setRotation(DISPLAY_ROTATION);  // 3 = USB port on the LEFT
  g_tft.fillScreen(TFT_BLACK);
}

TFT_eSPI &display() { return g_tft; }

void touchInit() {
  // Raw touch frame stays fixed (rotation 1); the 180° flip is applied
  // in touchTap so it stays exact regardless of calibration asymmetry.
  g_touchSPI.begin(PIN_TOUCH_CLK, PIN_TOUCH_MISO, PIN_TOUCH_MOSI, PIN_TOUCH_CS);
  g_touch.begin(g_touchSPI);
  g_touch.setRotation(1);
}

static bool s_down = false;
static unsigned long s_downMs = 0;

bool touchTap(uint16_t &x, uint16_t &y) {
  bool pressed = g_touch.touched();
  unsigned long now = millis();
  if (pressed && !s_down) {
    s_down = true;
    s_downMs = now;
    return false;
  }
  if (!pressed && s_down) {
    s_down = false;
    if (now - s_downMs > 600) return false;  // was a hold, not a tap
    TS_Point p = g_touch.getPoint();
    // Raw 12-bit -> screen pixels in the fixed raw frame, then flip for
    // DISPLAY_ROTATION 3 (USB on the left).
    long rx = constrain(p.x, TOUCH_RAW_X_MIN, TOUCH_RAW_X_MAX);
    long ry = constrain(p.y, TOUCH_RAW_Y_MIN, TOUCH_RAW_Y_MAX);
    x = (uint16_t)map(rx, TOUCH_RAW_X_MIN, TOUCH_RAW_X_MAX, 0, LAYOUT_W);
    y = (uint16_t)map(ry, TOUCH_RAW_Y_MIN, TOUCH_RAW_Y_MAX, 0, LAYOUT_H);
#if DISPLAY_ROTATION == 3
    x = LAYOUT_W - x;
    y = LAYOUT_H - y;
#endif
    return true;
  }
  return false;
}
EOF_DISP

cat > src/ui/screens.cpp <<'EOF_SCR'
#include "screens.h"
#include "display.h"
#include "ui_theme.h"
#include "config.h"
#include <math.h>

uint16_t statusColor(uint8_t status) {
  switch (status) {
    case ST_OK: return COLOR_GREEN;
    case ST_WARN: return COLOR_AMBER;
    case ST_CRIT: return COLOR_RED;
    default: return COLOR_BLUE;
  }
}

static uint16_t darken(uint16_t c) { return ((c >> 1) & 0x7BEF); }

static const char *screenSection(uint8_t scr) {
  switch (scr) {
    case SCR_PROVIDERS: return "02 · PROVIDERS";
    case SCR_SCOPE: return "03 · SCOPE";
    case SCR_CLOCK: return "04 · STANDBY";
    default: return "01 · QUOTA";
  }
}
extern uint8_t g_screen;  // owned by main.cpp

// Letterspaced micro label, analyzer-style.
static void spaced(const char *s, int x, int y, uint16_t color, uint16_t bg, uint8_t tracking = 2) {
  TFT_eSPI &t = display();
  t.setTextFont(2);
  t.setTextColor(color, bg);
  int cx = x;
  for (const char *c = s; *c; c++) {
    char b[2] = {*c, 0};
    t.setCursor(cx, y);
    t.print(b);
    cx += t.textWidth(b) + tracking;
  }
}

static void tiny(const char *s, int x, int y, uint16_t color, uint16_t bg) {
  TFT_eSPI &t = display();
  t.setTextFont(1);
  t.setTextColor(color, bg);
  t.setCursor(x, y);
  t.print(s);
}

static void header(const QuotaState &q, bool netUp, bool serialMode) {
  TFT_eSPI &t = display();
  t.setTextSize(1);
  t.setTextDatum(TL_DATUM);
  t.fillRect(0, 0, LAYOUT_W, HEADER_H, COLOR_CARD);
  spaced(screenSection(g_screen), 10, 6, COLOR_DIM, COLOR_CARD);

  uint16_t dot;
  const char *live;
  if (!q.fresh || !q.oc_connected) { dot = COLOR_DIM; live = "----"; }
  else if (q.oc_stale) { dot = COLOR_AMBER; live = "STALE"; }
  else { dot = COLOR_ICE; live = "LIVE"; }
  const char *link = serialMode ? "USB" : (netUp ? "WIFI" : "--");
  char clk[16];
  struct tm tm;
  if (getLocalTime(&tm, 0)) {
    snprintf(clk, sizeof(clk), "%02d:%02d", tm.tm_hour, tm.tm_min);
  } else if (q.fresh) {
    snprintf(clk, sizeof(clk), "-%lus", (millis() - q.updated_ms) / 1000);
  } else {
    snprintf(clk, sizeof(clk), "--:--");
  }

  // Right cluster packed from the edge: LIVE badge, link, clock. Never overlaps.
  t.setTextFont(2);
  int cx = LAYOUT_W - 10;
  t.setTextColor(dot, COLOR_CARD);
  int tw = t.textWidth(live);
  t.setCursor(cx - tw, 6);
  t.print(live);
  t.fillCircle(cx - tw - 8, HEADER_H / 2, 4, dot);
  cx -= tw + 18;
  t.setTextColor(COLOR_DIM, COLOR_CARD);
  tw = t.textWidth(link);
  t.setCursor(cx - tw, 6);
  t.print(link);
  cx -= tw + 8;
  tw = t.textWidth(clk);
  t.setCursor(cx - tw, 6);
  t.print(clk);
  t.drawFastHLine(0, HEADER_H, LAYOUT_W, COLOR_EDGE);
}

// Gradient meter bar with a white threshold marker at 20%.
static void meterBar(int x, int y, int w, int h, float pct, uint8_t status) {
  TFT_eSPI &t = display();
  t.drawRoundRect(x, y, w, h, 3, COLOR_EDGE);
  t.fillRoundRect(x + 1, y + 1, w - 2, h - 2, 2, COLOR_BG);
  float c = constrain(pct, 0, 100);
  int fill = (int)((c / 100.0f) * (w - 4));
  if (fill > 0) {
    uint16_t col = statusColor(status);
    t.fillRectHGradient(x + 2, y + 2, fill, h - 4, darken(col), col);
  }
  // crit-threshold marker
  int mx = x + 2 + (int)(0.2f * (w - 4));
  t.drawFastVLine(mx, y + 1, h - 2, COLOR_TEXT);
}

// Right-aligned value pair: big % colored + countdown dim.
static void rightPair(int y, const PoolState &p, int right) {
  TFT_eSPI &t = display();
  char cd[12];
  fmtCountdown(p.reset_in_sec, cd, sizeof(cd));
  char pct[10];
  snprintf(pct, sizeof(pct), "%.1f", p.remaining_pct);
  t.setTextFont(4);
  t.setTextColor(statusColor(p.status), COLOR_BG);
  int pw = t.textWidth(pct);
  t.setCursor(right - pw, y);
  t.print(pct);
  t.setTextFont(2);
  t.setTextColor(COLOR_DIM, COLOR_BG);
  t.setCursor(right - pw + 2, y + 26);
  t.print("%");
  t.setCursor(right - 62, y + 26);
  t.print(cd);
}

// Bottom readout strip: TOKENS | COST | NEXT, EBU-style.
static void readoutStrip(const QuotaState &q) {
  TFT_eSPI &t = display();
  const int y = LAYOUT_H - 30;
  t.drawFastHLine(MARGIN, y, LAYOUT_W - 2 * MARGIN, COLOR_EDGE);
  char v0[16], v1[16], v2[16];
  if (q.oc_tokens_k >= 1000) snprintf(v0, sizeof(v0), "%.1fM", q.oc_tokens_k / 1000.0f);
  else snprintf(v0, sizeof(v0), "%.0fk", q.oc_tokens_k);
  snprintf(v1, sizeof(v1), "$%.2f", q.oc_cost);
  if (q.oc_count) fmtCountdown(minReset(q), v2, sizeof(v2));
  else snprintf(v2, sizeof(v2), "--");

  const int c0 = MARGIN + 4, c1 = 118, c2 = 216;
  tiny("TOKENS", c0, y + 5, COLOR_DIM, COLOR_BG);
  tiny("COST", c1, y + 5, COLOR_DIM, COLOR_BG);
  tiny("NEXT", c2, y + 5, COLOR_DIM, COLOR_BG);
  t.setTextFont(2);
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  t.setCursor(c0, y + 14);
  t.print(v0);
  t.setCursor(c1, y + 14);
  t.print(v1);
  t.setTextColor(q.fresh ? COLOR_ICE : COLOR_DIM, COLOR_BG);
  t.setCursor(c2, y + 14);
  t.print(v2);
  t.drawFastVLine(110, y + 4, 22, COLOR_EDGE);
  t.drawFastVLine(208, y + 4, 22, COLOR_EDGE);
}

// Hero quota curve: cosine-interpolated area through the window levels.
// Panel geometry (320x240): x 8..312, y 36..172.
#define HERO_X0 8
#define HERO_X1 312
#define HERO_Y0 36
#define HERO_Y1 172
#define HERO_STEP 2
#define HERO_SAMPLES ((HERO_X1 - HERO_X0) / HERO_STEP + 1)

static int s_curveY[HERO_SAMPLES];

static uint16_t lerp565(uint16_t a, uint16_t b, uint8_t t /*0..255*/) {
  int ar = (a >> 11) & 0x1F, ag = (a >> 5) & 0x3F, ab = a & 0x1F;
  int br = (b >> 11) & 0x1F, bg = (b >> 5) & 0x3F, bb = b & 0x1F;
  int r = ar + ((br - ar) * t >> 8);
  int g = ag + ((bg - ag) * t >> 8);
  int bl = ab + ((bb - ab) * t >> 8);
  return (uint16_t)((r << 11) | (g << 5) | bl);
}

// Sample the smooth level curve. Levels: remaining% per provider, n>=1.
static void sampleCurve(const float *levels, uint8_t n) {
  float xs[POOLS_MAX], ys[POOLS_MAX];
  for (uint8_t i = 0; i < n; i++) {
    xs[i] = HERO_X0 + (i + 0.5f) * (HERO_X1 - HERO_X0) / n;
    float c = constrain(levels[i], 0, 100) / 100.0f;
    ys[i] = (HERO_Y1 - 6) - c * (HERO_Y1 - HERO_Y0 - 30);
  }
  for (int s = 0; s < HERO_SAMPLES; s++) {
    float x = HERO_X0 + s * HERO_STEP;
    float y;
    if (n < 2) {
      y = ys[0];
    } else if (x <= xs[0]) {
      y = ys[0];
    } else if (x >= xs[n - 1]) {
      y = ys[n - 1];
    } else {
      uint8_t k = 0;
      while (k < n - 2 && x > xs[k + 1]) k++;
      float mu = (x - xs[k]) / (xs[k + 1] - xs[k]);
      float m = (1.0f - cosf(mu * (float)M_PI)) * 0.5f;  // cosine ease
      y = ys[k] + (ys[k + 1] - ys[k]) * m;
    }
    s_curveY[s] = (int)y;
  }
}

// Centered small % readout for the scope ring.
static void charPct(int cx, int cy, float pct) {
  TFT_eSPI &t = display();
  char b[8];
  snprintf(b, sizeof(b), "%.0f", pct);
  t.setTextFont(2);
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  t.setTextDatum(MC_DATUM);
  t.drawString(b, cx, cy - 1);
  t.setTextDatum(TL_DATUM);
}

// Shorten "Go 5h" -> "5h" for the cramped hero labels.
static const char *shortName(const char *n) {
  if ((n[0] == 'G' || n[0] == 'g') && (n[1] == 'O' || n[1] == 'o') && n[2] == ' ')
    return n + 3;
  return n;
}

static void drawHeroPanel(const QuotaState &q) {
  TFT_eSPI &t = display();
  const int pw = HERO_X1 - HERO_X0, ph = HERO_Y1 - HERO_Y0;

  // Panel + grid.
  t.drawRoundRect(HERO_X0, HERO_Y0, pw, ph, 4, COLOR_EDGE);
  t.fillRoundRect(HERO_X0 + 1, HERO_Y0 + 1, pw - 2, ph - 2, 3, COLOR_BG);
  for (int gx = HERO_X0 + 38; gx < HERO_X1 - 4; gx += 38)
    t.drawFastVLine(gx, HERO_Y0 + 2, ph - 4, COLOR_GRID);
  for (int gy = HERO_Y0 + 27; gy < HERO_Y1 - 4; gy += 27)
    t.drawFastHLine(HERO_X0 + 2, gy, pw - 4, COLOR_GRID);

  uint8_t n = q.oc_count;
  if (n == 0 || n > POOLS_MAX) return;
  float levels[POOLS_MAX];
  for (uint8_t i = 0; i < n; i++) levels[i] = q.oc[i].remaining_pct;
  sampleCurve(levels, n);

  // Gradient area fill: 6 stacked bands per column.
  for (int s = 0; s < HERO_SAMPLES; s++) {
    int x = HERO_X0 + s * HERO_STEP;
    int top = constrain(s_curveY[s], HERO_Y0 + 2, HERO_Y1 - 1);
    int h = HERO_Y1 - 1 - top;
    if (h <= 0) continue;
    for (uint8_t b = 0; b < 6; b++) {
      int bh = h / 6 + (b < (uint8_t)(h % 6) ? 1 : 0);
      if (bh <= 0) continue;
      int by = top + (h * b) / 6;
      t.fillRect(x, by, HERO_STEP, bh, lerp565(COLOR_WAVE_TOP, COLOR_BG, (uint8_t)(b * 255 / 5)));
    }
  }
  // Ice outline.
  for (int s = 0; s < HERO_SAMPLES - 1; s++) {
    int x0 = HERO_X0 + s * HERO_STEP;
    t.drawLine(x0, s_curveY[s], x0 + HERO_STEP, s_curveY[s + 1], COLOR_ICE);
  }

  // Markers + band labels.
  t.setTextFont(2);
  for (uint8_t i = 0; i < n; i++) {
    int mx = (int)(HERO_X0 + (i + 0.5f) * pw / n);
    int my = (int)((HERO_Y1 - 6) - constrain(levels[i], 0, 100) / 100.0f * (ph - 30));
    t.fillCircle(mx, my, 3, COLOR_BG);
    t.drawCircle(mx, my, 3, COLOR_ICE);
    char lbl[28];
    snprintf(lbl, sizeof(lbl), "%s %.1f%%", shortName(q.oc[i].name), levels[i]);
    int lw = t.textWidth(lbl);
    int lx = constrain(mx - lw / 2, HERO_X0 + 3, HERO_X1 - 3 - lw);
    // Labels sit on the fill below their marker (white on blue reads well);
    // flip above only when the bottom would clip.
    int ly = my + 7;
    if (ly + 16 > HERO_Y1 - 3) ly = my - 22;
    t.setTextColor(COLOR_TEXT, COLOR_BG);
    t.setCursor(lx, ly);
    t.print(lbl);
  }

  // WINDOWS inset: mini level bars, bottom-left inside the panel.
  const int wx = HERO_X0 + 6, wy = HERO_Y1 - 36, ww = 52, wh = 30;
  t.fillRect(wx, wy, ww, wh, COLOR_BG);
  t.drawRect(wx, wy, ww, wh, COLOR_EDGE);
  tiny("WIN", wx + 4, wy + 3, COLOR_DIM, COLOR_BG);
  for (uint8_t i = 0; i < n && i < 4; i++) {
    int bh = (int)(constrain(levels[i], 0, 100) / 100.0f * 18.0f);
    int bx = wx + 5 + i * 12;
    if (bh > 0) t.fillRectVGradient(bx, wy + wh - 3 - bh, 9, bh, statusColor(q.oc[i].status), darken(statusColor(q.oc[i].status)));
  }

  // SCOPE inset: min-level ring gauge, bottom-right inside the panel
  // (the curve runs high, so the bottom corner stays clear).
  const int sx = HERO_X1 - 66, sy = HERO_Y1 - 56, sw = 60, sh = 50;
  t.fillRect(sx, sy, sw, sh, COLOR_BG);
  t.drawRect(sx, sy, sw, sh, COLOR_EDGE);
  tiny("SCOPE", sx + 4, sy + 3, COLOR_DIM, COLOR_BG);
  const int rcx = sx + sw - 20, rcy = sy + 30, rr = 14;
  float m = minRemaining(q);
  t.drawArc(rcx, rcy, rr, rr - 4, 0, 360, COLOR_EDGE, COLOR_EDGE, false);
  int end = (int)(constrain(m, 0, 100) / 100.0f * 360.0f);
  if (end > 0) {
    uint8_t st = ST_OK;
    for (uint8_t i = 0; i < n; i++) st = max(st, q.oc[i].status);
    t.drawArc(rcx, rcy, rr, rr - 4, 0, (uint32_t)end, statusColor(st), statusColor(st), true);
  }
  charPct(rcx, rcy, m);
}

void drawOverview(const QuotaState &q, bool netUp, bool serialMode) {
  display().fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  if (!q.oc_connected || q.oc_count == 0) {
    spaced("WAITING FOR BRIDGE", 60, 100, COLOR_DIM, COLOR_BG);
    tiny("CHECK WIFI + PORT 3847", 88, 124, COLOR_DIM, COLOR_BG);
    readoutStrip(q);
    return;
  }
  drawHeroPanel(q);
  readoutStrip(q);
}

void drawProviders(const QuotaState &q, bool netUp, bool serialMode) {
  TFT_eSPI &t = display();
  t.fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  if (!q.oc_connected || q.oc_count == 0) {
    spaced("NO PROVIDERS", 96, 110, COLOR_DIM, COLOR_BG);
    return;
  }
  int y = HEADER_H + 10;
  for (uint8_t i = 0; i < q.oc_count && i < POOLS_MAX; i++) {
    const PoolState &p = q.oc[i];
    char lbl[32];
    snprintf(lbl, sizeof(lbl), "P%d · %s", i + 1, p.name);
    spaced(lbl, 12, y, q.oc_stale ? COLOR_AMBER : COLOR_DIM, COLOR_BG);
    rightPair(y + 2, p, LAYOUT_W - 12);
    meterBar(12, y + 46, LAYOUT_W - 24, 8, p.remaining_pct, p.status);
    y += 62;
  }
}

void drawScope(const QuotaState &q, bool netUp, bool serialMode) {
  TFT_eSPI &t = display();
  t.fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  const int cx = 78, cy = 128, r = 50, th = 11;
  // Crosshair (vectorscope homage).
  t.drawFastHLine(cx - r - 8, cy, 2 * (r + 8), COLOR_EDGE);
  t.drawFastVLine(cx, cy - r - 8, 2 * (r + 8), COLOR_EDGE);
  // Tick dots around the ring (symmetric, no zero-point assumption).
  for (int a = 0; a < 360; a += 30) {
    float rad = a * (float)M_PI / 180.0f;
    int dx = (int)((r + 5) * sinf(rad));
    int dy = (int)(-(r + 5) * cosf(rad));
    t.fillCircle(cx + dx, cy + dy, 1, COLOR_DIM);
  }

  float m = minRemaining(q);
  uint8_t st = ST_OFFLINE;
  if (q.fresh && q.oc_connected) {
    st = ST_OK;
    for (uint8_t i = 0; i < q.oc_count; i++) st = max(st, q.oc[i].status);
  }
  // Background ring + progress arc.
  t.drawArc(cx, cy, r, r - th, 0, 360, COLOR_EDGE, COLOR_EDGE, false);
  if (q.fresh && q.oc_connected) {
    uint16_t col = statusColor(st);
    int end = (int)(constrain(m, 0, 100) / 100.0f * 360.0f);
    if (end > 0) t.drawArc(cx, cy, r, r - th, 0, (uint32_t)end, col, col, true);
  }
  // Provider dots on the ring.
  for (uint8_t i = 0; i < q.oc_count && i < 4; i++) {
    float rad = (i * 120.0f + 90.0f) * (float)M_PI / 180.0f;
    int dx = (int)(r * sinf(rad));
    int dy = (int)(-r * cosf(rad));
    t.fillCircle(cx + dx, cy + dy, 4, statusColor(q.oc[i].status));
    t.drawCircle(cx + dx, cy + dy, 4, COLOR_BG);
  }

  // Center readout, big: font4 fills the ring.
  char big[10];
  snprintf(big, sizeof(big), "%.0f", m);
  t.setTextFont(4);
  t.setTextColor(q.fresh ? COLOR_TEXT : COLOR_DIM, COLOR_BG);
  t.setTextDatum(MC_DATUM);
  t.drawString(big, cx, cy - 4);
  t.setTextDatum(TL_DATUM);
  tiny("MIN LEFT %", cx - 26, cy + 24, COLOR_DIM, COLOR_BG);

  // Right column: provider readouts.
  int y = 56;
  for (uint8_t i = 0; i < q.oc_count && i < 3; i++) {
    const PoolState &p = q.oc[i];
    char lbl[32];
    snprintf(lbl, sizeof(lbl), "P%d · %s", i + 1, p.name);
    spaced(lbl, 150, y, COLOR_DIM, COLOR_BG);
    rightPair(y + 14, p, LAYOUT_W - 12);
    y += 56;
  }
  tiny("TAP L/R · SCREENS", 150, LAYOUT_H - 18, COLOR_DIM, COLOR_BG);
}

void drawClock(const QuotaState &q, bool netUp, bool serialMode) {
  TFT_eSPI &t = display();
  t.fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  spaced("DESK CLOCK", 120, 44, COLOR_DIM, COLOR_BG);
  char hm[8] = "--:--";
  char date[24] = "";
  struct tm tm;
  if (getLocalTime(&tm, 0)) {
    snprintf(hm, sizeof(hm), "%02d:%02d", tm.tm_hour, tm.tm_min);
    snprintf(date, sizeof(date), "%04d-%02d-%02d", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday);
  }
  t.setTextFont(6);
  t.setTextSize(2);
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  t.setTextDatum(MC_DATUM);
  t.drawString(hm, LAYOUT_W / 2, 108);
  t.setTextSize(1);
  t.setTextFont(2);
  t.setTextColor(COLOR_DIM, COLOR_BG);
  t.drawString(date, LAYOUT_W / 2, 166);
  t.setTextDatum(TL_DATUM);

  // Level bars homage: provider remaining as vertical gradient bars.
  int bx = 60;
  for (uint8_t i = 0; i < q.oc_count && i < 4; i++) {
    int h = (int)(constrain(q.oc[i].remaining_pct, 0, 100) / 100.0f * 34.0f);
    uint16_t col = statusColor(q.oc[i].status);
    t.drawRect(bx, 186, 14, 36, COLOR_EDGE);
    if (h > 0) t.fillRectVGradient(bx + 1, 186 + 35 - h, 12, h, col, darken(col));
    bx += 24;
  }
  const char *msg = q.oc_connected ? "SYNCED" : "WAITING FOR BRIDGE";
  spaced(msg, 200, 196, q.fresh ? COLOR_ICE : COLOR_DIM, COLOR_BG);
}
EOF_SCR

cat > src/main.cpp <<'EOF_MAIN'
// NM-CYD Quota Monitor: 320x240 dashboard for Antigravity + OpenCode quotas.
#include <Arduino.h>
#include <WiFi.h>
#include "config.h"
#include "ui_theme.h"
#include "network.h"
#include "quota_state.h"
#include "led_controller.h"
#include "ui/display.h"
#include "ui/screens.h"

uint8_t g_screen = SCR_OVERVIEW;

static NetConfig g_cfg;
static QuotaState g_state;
static bool g_serialMode = false;
static unsigned long g_lastPoll = 0;
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
  if (netUp) pollNow();
  render();
  Serial.println("cyd-quota-monitor boot ok");
}

void loop() {
  serialPump();
  buttonTick();

  uint16_t tx, ty;
  if (touchTap(tx, ty)) {
    if (ty < HEADER_H) {
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
EOF_MAIN

echo "=== files synced, building ($ENV) ==="
pio run -e "$ENV"
echo "=== flashing to $PORT (hold BOOT if it fails to connect) ==="
pio run -e "$ENV" -t upload --upload-port "$PORT"
echo "=== DONE ($ENV) ==="
