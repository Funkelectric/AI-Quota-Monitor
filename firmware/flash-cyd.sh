#!/usr/bin/env bash
# NM-CYD Quota Monitor: build + flash (repo-canonical, non-clobbering).
# Usage: flash-cyd.sh [cyd-st7789|cyd-ili9341|tv154-st7789|tv154-diag] [--bootstrap]  (default: cyd-st7789)
# White/inverted screen after flashing => re-run with cyd-ili9341.
#
# AUDIT M11: repo files under firmware/ are canonical. By default this script
# builds IN PLACE (no copy, no overwrite). The legacy embedded-bootstrap that
# cat >'s full copies into ~/cyd-quota-monitor only runs with --bootstrap
# (fresh machine without a checkout) or when repo sources are missing.
# Use --check to diff target vs repo without building.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_FW="$SCRIPT_DIR"
BOOTSTRAP=0
CHECK=0
ENV="cyd-st7789"
for a in "$@"; do
  case "$a" in
    cyd-st7789|cyd-ili9341|tv154-st7789|tv154-diag) ENV="$a" ;;
    --bootstrap) BOOTSTRAP=1 ;;
    --check) CHECK=1 ;;
  esac
done

if [[ $BOOTSTRAP -eq 0 && -f "$REPO_FW/platformio.ini" && -f "$REPO_FW/src/main.cpp" ]]; then
  FW="$REPO_FW"
  if [[ $CHECK -eq 1 ]]; then
    echo "repo-canonical mode: FW=$FW (nothing to diff, building in place)"
  fi
  cd "$FW"
  export PATH="$HOME/.local/bin:$PATH"
  command -v pio >/dev/null || { echo "ERROR: platformio not found. Install with:"; echo "  sudo apt install -y python3-pip && pip install --user platformio --break-system-packages"; exit 1; }
  PORT="${PORT:-/dev/ttyUSB0}"
  # fall through to build+flash section at end of script
  # (skip the legacy cat > bootstrap blocks below)
  SKIP_BOOTSTRAP=1
else
  SKIP_BOOTSTRAP=$BOOTSTRAP
  # legacy path below handles --bootstrap / missing repo
  ENV="${1:-cyd-st7789}"
fi
PORT="${PORT:-/dev/ttyUSB0}"
export PATH="$HOME/.local/bin:$PATH"

command -v pio >/dev/null || { echo "ERROR: platformio not found. Install with:"; echo "  sudo apt install -y python3-pip && pip install --user platformio --break-system-packages"; exit 1; }

if [[ "${SKIP_BOOTSTRAP:-0}" -eq 1 && $BOOTSTRAP -eq 0 ]]; then
  : # repo-canonical: FW already set, sources untouched — jump to build
else
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
# Pinned for reproducibility (AUDIT H6): Arduino core v2 vs v3 changes
# analogWrite/LEDC behaviour silently. Tested with platformio 6.2.0.
platform = espressif32@6.8.1
board = esp32dev
framework = arduino
# NOTE: huge_app.csv = NO OTA partition. Every future update needs USB.
# Intentional for single-app CYD use; document before changing.
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
  -D TOUCH_CS=-1
  -D LOAD_GLCD=1
  -D LOAD_FONT2=1
  -D LOAD_FONT4=1
  -D LOAD_FONT6=1
  -D LOAD_FONT7=1
  -D LOAD_FONT8=1
  -D CYD_ST7789=1
  -D TFT_INVERSION_ON=1
  ; Panel-specific quirk flag consumed in screens.cpp (RGB/BGR order note):
  ; ST7789V on this revision needs INVERSION_ON; if red/blue swap appears,
  ; add -D TFT_RGB_ORDER=TFT_BGR. Kept explicit per-revision (AUDIT H6).
lib_deps =
  bodmer/TFT_eSPI@^2.5.43
  bblanchon/ArduinoJson@^7.0.4
  tzapu/WiFiManager@^2.0.17
  https://github.com/PaulStoffregen/XPT2046_Touchscreen.git

[env:tv154-diag]
# Sweep diagnostic: tries all LCD-PWR(21) x BL(19) combos, reports via serial.
# Same panel flags as tv154-st7789; only diag_main.cpp compiles (see filter).
platform = espressif32@6.8.1
board = esp32dev
framework = arduino
board_build.partitions = huge_app.csv
monitor_speed = 115200
build_flags =
  -D USER_SETUP_LOADED=1
  -D ST7789_DRIVER=1
  -D TV154=1
  -D CGRAM_OFFSET=1
  -D USE_HSPI_PORT=1
  -D TFT_WIDTH=240
  -D TFT_HEIGHT=240
  -D TFT_MOSI=13
  -D TFT_MISO=-1
  -D TFT_SCLK=14
  -D TFT_CS=15
  -D TFT_DC=2
  -D TFT_RST=-1
  -D TFT_BL=19
  -D TFT_BACKLIGHT_ON=0
  -D SPI_FREQUENCY=40000000
  -D SPI_READ_FREQUENCY=20000000
  -D TFT_INVERSION_ON=1
  -D TOUCH_CS=-1
  -D LOAD_GLCD=1
  -D LOAD_FONT2=1
lib_deps =
  Bodmer/TFT_eSPI@^2.5.43
build_src_filter =
  +<*>
  -<.git/>
  -<main.cpp>
  -<network.cpp>
  -<quota_state.cpp>
  -<ask_state.cpp>
  -<led_controller.cpp>
  -<ui/display.cpp>
  -<ui/screens.cpp>

[env:cyd-ili9341]
extends = env:cyd-st7789
; Proven on this unit (2026-11-19): alt ILI9341 init fixes column offset,
; inversion ON restores black bg + blue palette. Stock ILI9341_DRIVER shows
; rotated + noise on this panel; ST7789 builds show inverted colors.
build_flags =
  -D USER_SETUP_LOADED=1
  -D ILI9341_2_DRIVER=1
  -D TFT_INVERSION_ON=1
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
  ; ILI9341 typically specced ~30MHz max write; 40MHz glitches/tears on
  ; marginal panels (AUDIT H6). Proven stable at 27MHz on this unit.
  -D SPI_FREQUENCY=27000000
  -D TOUCH_CS=-1
  -D LOAD_GLCD=1
  -D LOAD_FONT2=1
  -D LOAD_FONT4=1
  -D LOAD_FONT6=1
  -D LOAD_FONT7=1
  -D LOAD_FONT8=1
  -D CYD_ILI9341_DRIVER=1

; NM-TV-154 port (1.54" 240x240 square, ESP32-D0, top button, no XPT2046).
; Screen scope: 01 QUOTA + 02 WINDOWS only. Bridge unchanged (same /api/quota).
; Pins verified against RockBase-lab/NM-TV-154 (ST7789 HSPI, BL GPIO19
; active-low, LCD power GPIO21 active-low, touch T9/GPIO32, no MISO, no LDR/RGB).
[env:tv154-st7789]
platform = espressif32@6.8.1
board = esp32dev
framework = arduino
board_build.partitions = huge_app.csv
monitor_speed = 115200
build_flags =
  -D USER_SETUP_LOADED=1
  -D ST7789_DRIVER=1
  -D TV154=1
  -D CGRAM_OFFSET=1
  -D USE_HSPI_PORT=1
  -D TFT_WIDTH=240
  -D TFT_HEIGHT=240
  -D TFT_MOSI=13
  -D TFT_MISO=-1
  -D TFT_SCLK=14
  -D TFT_CS=15
  -D TFT_DC=2
  -D TFT_RST=-1
  -D TFT_BL=19
  -D TFT_BACKLIGHT_ON=0
  -D SPI_FREQUENCY=40000000
  -D SPI_READ_FREQUENCY=20000000
  -D TFT_INVERSION_ON=1
  -D TOUCH_CS=-1
  -D LOAD_GLCD=1
  -D LOAD_FONT2=1
  -D LOAD_FONT4=1
  -D LOAD_FONT6=1
  -D LOAD_FONT7=1
  -D LOAD_FONT8=1
  -D TV154_ST7789=1
lib_deps =
  bodmer/TFT_eSPI@^2.5.43
  bblanchon/ArduinoJson@^7.0.4
  tzapu/WiFiManager@^2.0.17
EOF_INI

cat > include/config.h <<'EOF_CFG'
#pragma once

// Pin map for ESP32-2432S028R (NM-CYD), landscape 320x240.
#ifdef TV154
// NM-TV-154 (verified vs RockBase-lab/NM-TV-154): ST7789 240x240 on HSPI,
// BL GPIO19 active-low, LCD power rail GPIO21 active-low, touch T9/GPIO32.
// No MISO, no XPT2046, no RGB LED, no LDR.
#define PIN_TFT_MOSI 13
#define PIN_TFT_MISO -1
#define PIN_TFT_SCLK 14
#define PIN_TFT_CS   15
#define PIN_TFT_DC    2
#define PIN_TFT_RST  -1
#define PIN_TFT_BL   19
#define PIN_LCD_PWR  21
#define PIN_TOUCH_T9 T9
#define TOUCH_THRESHOLD 90
#define HAS_LDR 0
#define HAS_RGB 0
#else
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
#endif // TV154 / CYD pin map

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
#define SCR_ASK       4
#ifdef TV154
// TV-154 port scope: 01 QUOTA + 02 WINDOWS only (240x240, single button).
#define SCR_COUNT     2
#define HAS_XPT2046   0
#else
#define SCR_COUNT     5
#define HAS_XPT2046   1
#endif

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
#define SESSIONS_MAX 4
#define SESSION_TITLE_MAX 23
#define SESSION_MODEL_MAX 31

// 05 ASK screen: question queue state (<1KB payload).
// NOTE: ASK_ID_MAX=31 unified with bridge (bridge slices ids to 31, see
// bridge/src/askStore.ts MAX_ID). Was 15 -> 16-char bridge ids truncated on
// tap and answered 410 + wrong-option fallback (AUDIT C3).
#define ASK_JSON_MAX 1024
#define ASK_QUESTION_MAX 120
#define ASK_DETAIL_MAX 48
#define ASK_OPTS_MAX 4
#define ASK_OPT_LABEL_MAX 24
#define ASK_ID_MAX 31
#define ASK_POLL_SEC 5

// WiFi reconnect: non-blocking re-associate attempt every 30s when offline.
// Fixes C1 (drop latched offline forever). NTP re-synced on regain.
#define WIFI_RECONNECT_SEC 30
#define WIFI_RECONNECT_MS (WIFI_RECONNECT_SEC * 1000UL)

// Backlight: EMA + deadband + fast slew (fixes H5 slow 107s swing).
#define BL_EMA_N 4
#define BL_SLEW_STEP 8
#define BL_DEADBAND 4
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
// TV154: square 240x240, rotation 0 matches stock/demo orientation.
#ifdef TV154
#define DISPLAY_ROTATION 0
#else
#define DISPLAY_ROTATION 3
#endif

// Layout (landscape 320x240; TV154: square 240x240).
#ifdef TV154
#define LAYOUT_W        240
#define LAYOUT_H        240
#else
#define LAYOUT_W        320
#define LAYOUT_H        240
#endif
#define HEADER_H        28
#define MARGIN          8
#define CARD_R          6

// TV154 240px geometry (from mock_tv154_render.py audit):
// - hero panel x 8..231 (was 8..311), value anchor 180->132,
// - readoutStrip cols [12,118,216]->[12,92,168], dividers 110/208->84/164.
#ifdef TV154
#define TV154_HERO_X1   231
#define TV154_CENTER_X  132
#define TV154_C0        12
#define TV154_C1        92
#define TV154_C2        168
#define TV154_DIV0      84
#define TV154_DIV1      164
#endif

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

/** GET http://host:port/api/ask. True+pending on 200, true+!pending on 204, false on error. */
bool netFetchAsk(const NetConfig &cfg, struct AskState &out);

/** POST http://host:port/api/ask/answer {id, option_id}. True on 200. */
bool netPostAnswer(const NetConfig &cfg, const char *id, const char *option_id);

/**
 * Non-blocking WiFi maintenance (AUDIT C1 / P0-1).
 * Call every loop(): when offline, attempts WiFi.reconnect() at most every
 * WIFI_RECONNECT_SEC and re-runs NTP (configTzTime) once on regain.
 * Never blocks; never opens the portal (portal only via BOOT long-press).
 */
void netTick();

bool netIsConnected();

/** Optional bearer for POST /api/ask/answer when bridge sets CYD_TOKEN (P3-17). */
void netSetToken(const char *token);
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
EOF_QSH

cat > src/ask_state.h <<'EOF_ASKH'
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
EOF_ASKH

cat > src/ask_state.cpp <<'EOF_ASKC'
#include "ask_state.h"
#include <ArduinoJson.h>
#include <string.h>

static void copyAsk(char *dst, size_t dstLen, const char *src) {
  if (!src) src = "?";
  strncpy(dst, src, dstLen - 1);
  dst[dstLen - 1] = '\0';
}

// Own static doc: never shares quota_state's document (heap-stable for soak).
// Fixed capacity per AUDIT M4 (was unbounded dynamic JsonDocument).
static StaticJsonDocument<1024> g_askDoc;

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
EOF_ASKC

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
#include "ask_state.h"

// netUp: WiFi connected. serialMode: showing USB-serial data path.
void drawOverview(const QuotaState &q, bool netUp, bool serialMode);
void drawProviders(const QuotaState &q, bool netUp, bool serialMode);
void drawScope(const QuotaState &q, bool netUp, bool serialMode);
void drawClock(const QuotaState &q, bool netUp, bool serialMode);
void drawAsk(const AskState &a, const QuotaState &q, bool netUp, bool serialMode);
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
  // AUDIT M7: sub-minute shows seconds (45s), sub-2min shows m+sec? Keep
  // compact: <60s -> "45s", <120s -> "1m 45s" is too long for 12ch buf,
  // so <120s shows seconds only ("95s"). Hours/days unchanged.
  if (sec < 60) {
    snprintf(out, outLen, "%lds", sec);
  } else if (sec < 120) {
    snprintf(out, outLen, "%lds", sec);
  } else if (sec < 3600) {
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
// AUDIT M4: fixed-capacity static pools (no unbounded dynamic growth).
static StaticJsonDocument<2048> g_doc;

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
EOF_QS

cat > src/led_controller.cpp <<'EOF_LED'
#include "led_controller.h"

// Active-LOW common-anode LED: analogWrite(pin, 255) = OFF.
static void ledWrite(uint8_t pin, uint8_t brightness) {
  analogWrite(pin, 255 - brightness);
}

void ledInit() {
#ifdef TV154
  // No RGB LED on NM-TV-154: nothing to init.
  return;
#else
  pinMode(PIN_LED_R, OUTPUT);
  pinMode(PIN_LED_G, OUTPUT);
  pinMode(PIN_LED_B, OUTPUT);
  ledWrite(PIN_LED_R, 0);
  ledWrite(PIN_LED_G, 0);
  ledWrite(PIN_LED_B, 0);
#endif
}

void ledTick(uint8_t status) {
#ifdef TV154
  (void)status;
  return;
#else
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
#endif
}

static uint8_t g_bl = 255;

void backlightInit() {
#ifdef TV154
  // NM-TV-154 backlight GPIO19 is active-low: LOW = full brightness.
  // No LDR on this board, so fixed full-on (tick is a no-op).
  pinMode(PIN_TFT_BL, OUTPUT);
  digitalWrite(PIN_TFT_BL, LOW);
#else
  pinMode(PIN_TFT_BL, OUTPUT);
  analogWrite(PIN_TFT_BL, g_bl);
#endif
}

void backlightSet(uint8_t duty) {
  g_bl = duty;
#ifdef TV154
  analogWrite(PIN_TFT_BL, (uint8_t)(255 - duty));  // active-low: invert
#else
  analogWrite(PIN_TFT_BL, duty);
#endif
}

void backlightTick() {
#ifdef TV154
  return;  // no LDR on NM-TV-154: brightness fixed at init
#else
  // LDR on GPIO34: brighter room -> higher ADC -> brighter backlight.
  // Clamp to a readable floor so the screen never goes fully dark.
  // AUDIT H5: EMA + deadband + fast slew. Raw single-sample stepped ±1/tick
  // (107s full swing); now 4-sample EMA, ±8/tick, ±4 deadband -> <5s room
  // transitions, no dither flicker at thresholds.
  static float ema = -1.0f;
#if defined(ESP32)
  analogSetAttenuation(ADC_11db);
#endif
  int raw = analogRead(PIN_LDR);
  if (ema < 0) ema = (float)raw;
  else ema += ((float)raw - ema) / (float)BL_EMA_N;
  int smooth = (int)(ema + 0.5f);
  uint8_t target = (uint8_t)constrain(map(smooth, 200, 3500, 40, 255), 40, 255);
  int diff = (int)target - (int)g_bl;
  if (abs(diff) <= (int)BL_DEADBAND) return;  // hysteresis: ignore noise
  int step = diff > 0 ? diff : -diff;
  if (step > (int)BL_SLEW_STEP) step = (int)BL_SLEW_STEP;
  int next = (int)g_bl + (diff > 0 ? step : -step);
  if (next > 255) next = 255;
  if (next < 40) next = 40;
  g_bl = (uint8_t)next;
  analogWrite(PIN_TFT_BL, g_bl);
#endif
}
EOF_LED

cat > src/network.cpp <<'EOF_NET'
#include "network.h"
#include "quota_state.h"
#include "ask_state.h"
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
  // AUDIT M3: no Arduino String on the read path (heap-stable); getString
  // directly into a stack buffer, then copy with truncation guard.
  char hbuf[sizeof(cfg.host)];
  size_t n = p.getString(NVS_KEY_HOST, hbuf, sizeof(hbuf));
  if (n > 0) {
    strncpy(cfg.host, hbuf, sizeof(cfg.host) - 1);
    cfg.host[sizeof(cfg.host) - 1] = '\0';
  }
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
  // AUDIT C1: stay in STA + auto-reconnect so roams/DHCP expiry recover.
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.persistent(true);
  if (WiFi.status() == WL_CONNECTED && !forcePortal) return true;
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
    // AUDIT M2: reject oversize bodies up-front; chunked (-1) still bounded
    // by QUOTA_JSON_MAX + the 1.5s stall heuristic below.
    int len = http.getSize();
    if (len > QUOTA_JSON_MAX) {
      http.end();
      return false;
    }
    if (len < 0) len = QUOTA_JSON_MAX;
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

static unsigned long s_lastReconnectTry = 0;
static bool s_ntpDone = false;

void netTick() {
  // Called every loop(). Non-blocking: at most one reconnect attempt per
  // WIFI_RECONNECT_SEC, no portal, no delay().
  if (WiFi.status() == WL_CONNECTED) {
    if (!s_ntpDone) {
      // Regained link (or first connect without portal path): re-sync clock.
      configTzTime(NTP_TZ, NTP_SERVER_1, NTP_SERVER_2);
      s_ntpDone = true;
    }
    return;
  }
  unsigned long now = millis();
  if (now - s_lastReconnectTry < WIFI_RECONNECT_MS) return;
  s_lastReconnectTry = now;
  s_ntpDone = false;
  WiFi.disconnect(false, false);
  WiFi.reconnect();
}

bool netIsConnected() { return WiFi.status() == WL_CONNECTED; }

// Shared ask buffer (separate from quota buffer so polls never interleave).
static char g_askBuf[ASK_JSON_MAX + 1];

bool netFetchAsk(const NetConfig &cfg, AskState &out) {
  if (WiFi.status() != WL_CONNECTED) return false;
  char url[128];
  snprintf(url, sizeof(url), "http://%s:%u/api/ask", cfg.host, cfg.port);

  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
  if (!http.begin(url)) return false;
  int code = http.GET();
  if (code == 204) {
    http.end();
    out.pending = false;
    out.fresh = true;
    return true;
  }
  bool ok = false;
  if (code == 200) {
    int len = http.getSize();
    if (len > ASK_JSON_MAX) {
      http.end();
      return false;
    }
    if (len < 0) len = ASK_JSON_MAX;
    WiFiClient *stream = http.getStreamPtr();
    size_t n = 0;
    unsigned long deadline = millis() + HTTP_TIMEOUT_MS;
    unsigned long lastProgress = millis();
    while (n < (size_t)len && millis() < deadline) {
      while (stream->available() && n < ASK_JSON_MAX) {
        g_askBuf[n++] = (char)stream->read();
        lastProgress = millis();
      }
      if ((int)n >= len && len > 0) break;
      if (millis() - lastProgress > 1500) break;
      delay(1);
    }
    ok = parseAskPayload(g_askBuf, n, out);
  }
  http.end();
  return ok;
}

static char s_token[64] = "";

void netSetToken(const char *token) {
  if (!token) token = "";
  strncpy(s_token, token, sizeof(s_token) - 1);
  s_token[sizeof(s_token) - 1] = '\0';
}

bool netPostAnswer(const NetConfig &cfg, const char *id, const char *option_id) {
  if (WiFi.status() != WL_CONNECTED || !id || !option_id) return false;
  char url[128];
  snprintf(url, sizeof(url), "http://%s:%u/api/ask/answer", cfg.host, cfg.port);

  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
  if (!http.begin(url)) return false;
  http.addHeader("Content-Type", "application/json");
  if (s_token[0]) {
    char auth[80];
    snprintf(auth, sizeof(auth), "Bearer %.64s", s_token);
    http.addHeader("Authorization", auth);
  }
  // ASK_ID_MAX=31 unified with bridge (AUDIT C3). Body sized for 31+31 + JSON.
  char body[128];
  snprintf(body, sizeof(body), "{\"id\":\"%.31s\",\"option_id\":\"%.31s\"}", id, option_id);
  int code = http.POST((uint8_t *)body, strlen(body));
  http.end();
  return code == 200;
}
EOF_NET

cat > src/ui/display.cpp <<'EOF_DISP'
#include "display.h"
#include <SPI.h>
#include "config.h"
#include "ui_theme.h"
#if HAS_XPT2046
#include <XPT2046_Touchscreen.h>
#endif

static TFT_eSPI g_tft;
#if HAS_XPT2046
static SPIClass g_touchSPI(VSPI);
static XPT2046_Touchscreen g_touch(PIN_TOUCH_CS, PIN_TOUCH_IRQ);
#endif

void displayInit() {
#ifdef TV154
  // NM-TV-154: LCD power rail MUST be enabled before init, else black screen.
  // (RockBase-lab/NM-TV-154: GPIO21 LOW = rail enabled.)
  pinMode(PIN_LCD_PWR, OUTPUT);
  digitalWrite(PIN_LCD_PWR, LOW);
  delay(50);
#endif
  g_tft.init();
  g_tft.setRotation(DISPLAY_ROTATION);  // 3 = USB port on the LEFT
  g_tft.fillScreen(TFT_BLACK);
}

TFT_eSPI &display() { return g_tft; }

void touchInit() {
#if !HAS_XPT2046
  // TV-154: single top button, no XY touch. Kept as no-op so main.cpp
  // compiles unchanged; navigation falls back to the BOOT/button path.
  return;
#else
  // Raw touch frame stays fixed (rotation 1); the 180° flip is applied
  // in touchTap so it stays exact regardless of calibration asymmetry.
  g_touchSPI.begin(PIN_TOUCH_CLK, PIN_TOUCH_MISO, PIN_TOUCH_MOSI, PIN_TOUCH_CS);
  g_touch.begin(g_touchSPI);
  g_touch.setRotation(1);
#endif
}

#if !HAS_XPT2046
bool touchTap(uint16_t &x, uint16_t &y) {
  (void)x; (void)y;
  return false;
}
#else
static bool s_down = false;
static unsigned long s_downMs = 0;
static TS_Point s_downPt;
static bool s_downValid = false;

bool touchTap(uint16_t &x, uint16_t &y) {
  bool pressed = g_touch.touched();
  unsigned long now = millis();
  if (pressed && !s_down) {
    s_down = true;
    s_downMs = now;
    // AUDIT H9: sample at press, not release (release reads post-lift stale).
    s_downPt = g_touch.getPoint();
    s_downValid = true;
    return false;
  }
  if (!pressed && s_down) {
    s_down = false;
    if (now - s_downMs > 600) { s_downValid = false; return false; }
    if (!s_downValid) return false;
    s_downValid = false;
    TS_Point p = s_downPt;
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
#endif
EOF_DISP

cat > src/ui/screens.cpp <<'EOF_SCR'
#include "screens.h"
#include "display.h"
#include "ask_state.h"
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
  // AUDIT H3: ASCII '-' only. TFT_eSPI bitmap fonts (font1/font2) are 7-bit;
  // UTF-8 middle-dot renders as two garbage glyphs on-device.
  switch (scr) {
#ifdef TV154
    // 240px: "02 - PROVIDERS" (130px spaced) collides with the clock cluster;
    // "02 - WINDOWS" (114px) keeps an 8px gap (see mock_tv154_render.py audit).
    case SCR_PROVIDERS: return "02 - WINDOWS";
#else
    case SCR_PROVIDERS: return "02 - PROVIDERS";
#endif
    case SCR_SCOPE: return "03 - SCOPE";
    case SCR_CLOCK: return "04 - STANDBY";
    case SCR_ASK: return "05 - ASK";
    default: return "01 - QUOTA";
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

// Legacy right-aligned pair (kept for 03 SCOPE narrow column).
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
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  t.setCursor(right - pw + 2, y + 26);
  t.print("%");
  t.setCursor(right - 62, y + 26);
  t.print(cd);
}

// Centered value: big % near-center, countdown right-aligned + readable.
// CYD: % anchors at x=180 (not 160) so long "GO MONTH" labels never overlap.
// TV154 240px: free zone is label-end (~92) .. countdown-start (~174),
// so anchor at 132 (see mock_tv154_render.py audit).
static void centerPair(int y, const PoolState &p, int right) {
  TFT_eSPI &t = display();
  char cd[12];
  fmtCountdown(p.reset_in_sec, cd, sizeof(cd));
  char pct[12];
  snprintf(pct, sizeof(pct), "%.1f%%", p.remaining_pct);
  t.setTextFont(4);
  t.setTextColor(statusColor(p.status), COLOR_BG);
  int pw = t.textWidth(pct);
#ifdef TV154
  t.setCursor(TV154_CENTER_X - pw / 2, y);
#else
  t.setCursor(180 - pw / 2, y);
#endif
  t.print(pct);
  t.setTextFont(2);
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  int cw = t.textWidth(cd);
  t.setCursor(right - cw, y + 8);
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

#ifdef TV154
  const int c0 = TV154_C0, c1 = TV154_C1, c2 = TV154_C2;
#else
  const int c0 = MARGIN + 4, c1 = 118, c2 = 216;
#endif
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
#ifdef TV154
  t.drawFastVLine(TV154_DIV0, y + 4, 22, COLOR_EDGE);
  t.drawFastVLine(TV154_DIV1, y + 4, 22, COLOR_EDGE);
#else
  t.drawFastVLine(110, y + 4, 22, COLOR_EDGE);
  t.drawFastVLine(208, y + 4, 22, COLOR_EDGE);
#endif
}

// Hero quota curve: cosine-interpolated area through the window levels.
// Panel geometry 320x240: x 8..312, y 36..172. TV154 240x240: x 8..231.
#ifdef TV154
#define HERO_X0 8
#define HERO_X1 TV154_HERO_X1
#else
#define HERO_X0 8
#define HERO_X1 312
#endif
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
#ifdef TV154
  // 240px: marker slots are 74px but labels are 60-86px, so neighbours
  // collide. Try below-marker first (v1 law), flip above on bottom-clip
  // OR intersection with an already placed label (see mock_tv154_render.py).
  int plx[POOLS_MAX], plx1[POOLS_MAX], ply[POOLS_MAX], ply1[POOLS_MAX];
  for (uint8_t i = 0; i < n; i++) {
    int mx = (int)(HERO_X0 + (i + 0.5f) * pw / n);
    int my = (int)((HERO_Y1 - 6) - constrain(levels[i], 0, 100) / 100.0f * (ph - 30));
    t.fillCircle(mx, my, 3, COLOR_BG);
    t.drawCircle(mx, my, 3, COLOR_ICE);
    char lbl[28];
    snprintf(lbl, sizeof(lbl), "%s %.1f%%", shortName(q.oc[i].name), levels[i]);
    int lw = t.textWidth(lbl);
    int lx = constrain(mx - lw / 2, HERO_X0 + 3, HERO_X1 - 3 - lw);
    int below = my + 7, above = my - 22;
    int ly = below;
    if (ly + 16 > HERO_Y1 - 3) ly = above;
    // Flip to whichever side avoids already-placed boxes.
    bool hit = false;
    for (uint8_t j = 0; j < i; j++) {
      if (lx < plx1[j] && lx + lw > plx[j] && ly < ply1[j] && ly + 16 > ply[j]) { hit = true; break; }
    }
    if (hit) {
      int alt = (ly == below) ? above : below;
      if (alt >= HERO_Y0 + 2 && alt + 16 <= HERO_Y1 - 2) ly = alt;
    }
    plx[i] = lx; plx1[i] = lx + lw; ply[i] = ly; ply1[i] = ly + 16;
    t.setTextColor(COLOR_TEXT, COLOR_BG);
    t.setCursor(lx, ly);
    t.print(lbl);
  }
#else
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
#endif
}

// Session rotator strip: conversation title + model between hero graph and
// bottom readout. Rotates one session per 10s render (matches main.cpp tick).
// Gap geometry: hero ends y=172, strip hairline y=210 → text at y=184..200.
static void sessionStrip(const QuotaState &q) {
  TFT_eSPI &t = display();
  tiny("SESSION", MARGIN, 176, COLOR_DIM, COLOR_BG);
  if (q.session_count == 0) {
    t.setTextFont(2);
    t.setTextColor(COLOR_DIM, COLOR_BG);
    t.setCursor(MARGIN, 186);
    t.print("-- idle --");
    return;
  }
  uint8_t idx = (uint8_t)((millis() / 10000UL) % q.session_count);
  const SessionState &s = q.sessions[idx];
  if (q.session_count > 1) {
    char pager[8];
    snprintf(pager, sizeof(pager), "%d/%d", idx + 1, q.session_count);
    t.setTextFont(1);
    int pw = t.textWidth(pager);
    t.setTextColor(COLOR_DIM, COLOR_BG);
    t.setCursor(LAYOUT_W - MARGIN - pw, 176);
    t.print(pager);
  }
  char line[SESSION_TITLE_MAX + SESSION_MODEL_MAX + 4];
  snprintf(line, sizeof(line), "%s - %s", s.title, s.model);
  t.setTextFont(2);
  while (strlen(line) > 1 && t.textWidth(line) > LAYOUT_W - MARGIN * 2) line[strlen(line) - 1] = '\0';
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  t.setCursor(MARGIN, 186);
  t.print(line);
}

void drawOverview(const QuotaState &q, bool netUp, bool serialMode) {
  display().fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  if (!q.oc_connected || q.oc_count == 0) {
#ifdef TV154
    spaced("WAITING FOR BRIDGE", 20, 100, COLOR_DIM, COLOR_BG);
    tiny("CHECK WIFI + PORT 3847", 48, 124, COLOR_DIM, COLOR_BG);
#else
    spaced("WAITING FOR BRIDGE", 60, 100, COLOR_DIM, COLOR_BG);
    tiny("CHECK WIFI + PORT 3847", 88, 124, COLOR_DIM, COLOR_BG);
#endif
    readoutStrip(q);
    return;
  }
  drawHeroPanel(q);
  sessionStrip(q);
  readoutStrip(q);
}

void drawProviders(const QuotaState &q, bool netUp, bool serialMode) {
  TFT_eSPI &t = display();
  t.fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  if (!q.oc_connected || q.oc_count == 0) {
#ifdef TV154
    spaced("NO PROVIDERS", 56, 110, COLOR_DIM, COLOR_BG);
#else
    spaced("NO PROVIDERS", 96, 110, COLOR_DIM, COLOR_BG);
#endif
    return;
  }
  int y = HEADER_H + 10;
  // AUDIT H2: 4 pools must fit 240px. 3 rows use roomy y+=64; 4 rows switch
  // to condensed y+=50 (meter at y+38) so the 4th meter ends at ~236px.
  const bool condensed = (q.oc_count >= 4);
  const int yStep = condensed ? 50 : 64;
  const int meterY = condensed ? 38 : 46;
  for (uint8_t i = 0; i < q.oc_count && i < POOLS_MAX; i++) {
    const PoolState &p = q.oc[i];
    spaced(p.name, 12, y, q.oc_stale ? COLOR_AMBER : COLOR_DIM, COLOR_BG);
    centerPair(y + 2, p, LAYOUT_W - 12);
    meterBar(12, y + meterY, LAYOUT_W - 24, 10, p.remaining_pct, p.status);
    y += yStep;
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
  // AUDIT H2: cap at 3 rows on scope (firmware holds 4, bridge sends 4 max;
  // 4th row would collide with the hint line). H3: ASCII '-' separator.
  int y = 56;
  for (uint8_t i = 0; i < q.oc_count && i < 3; i++) {
    const PoolState &p = q.oc[i];
    char lbl[32];
    snprintf(lbl, sizeof(lbl), "P%d - %s", i + 1, p.name);
    spaced(lbl, 150, y, COLOR_DIM, COLOR_BG);
    rightPair(y + 14, p, LAYOUT_W - 12);
    y += 56;
  }
  tiny("TAP L/R - SCREENS", 150, LAYOUT_H - 18, COLOR_DIM, COLOR_BG);
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

// ---- 05 ASK: OpenCode question with bottom touch buttons ----
// Geometry mirrors mock_hw_render.py:screen_ask() (ASK_BTNS_* boxes).
// 3-up: (8,172,97,48) (111,172,97,48) (214,172,98,48)
// 2-up: (8,172,149,48) (163,172,149,48)
// 1-up centered: (86,172,148,48)  -- AUDIT M6 (was left-aligned 97px)
// 4-grid: (8,124,149,44) (163,124,149,44) (8,174,149,44) (163,174,149,44)
// Single-option button box shared with askHit() in main.cpp - keep in sync.
#define ASK_SINGLE_X 86
#define ASK_SINGLE_W 148
#define ASK_SINGLE_Y 172
#define ASK_SINGLE_H 48
static void askButton(int x, int y, int w, int h, const char *label) {
  TFT_eSPI &t = display();
  t.drawRoundRect(x, y, w, h, 3, COLOR_EDGE);
  t.fillRoundRect(x + 1, y + 1, w - 2, h - 2, 2, COLOR_CARD);
  char b[ASK_OPT_LABEL_MAX + 1];
  strncpy(b, label, sizeof(b) - 1);
  b[sizeof(b) - 1] = '\0';
  t.setTextFont(2);
  while (strlen(b) > 1 && t.textWidth(b) > w - 12) b[strlen(b) - 1] = '\0';
  t.setTextColor(COLOR_TEXT, COLOR_CARD);
  t.setCursor(x + (w - t.textWidth(b)) / 2, y + (h - 16) / 2);
  t.print(b);
}

void drawAsk(const AskState &a, const QuotaState &q, bool netUp, bool serialMode) {
  TFT_eSPI &t = display();
  t.fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  if (!a.pending) {
    spaced("NO QUESTION", 100, 110, COLOR_DIM, COLOR_BG);
    return;
  }

  // AUDIT M6: word-wrap question to 2 lines instead of mid-word chop.
  // Splits on spaces to fit 292px; second line truncated with ellipsis budget.
  auto drawWrapped = [&](int y0) {
    char line1[ASK_QUESTION_MAX + 1] = "";
    char line2[ASK_QUESTION_MAX + 1] = "";
    // Greedy fill line1.
    const char *p = a.question;
    char word[48];
    t.setTextFont(2);
    while (*p) {
      // skip spaces
      while (*p == ' ') p++;
      if (!*p) break;
      size_t wi = 0;
      while (*p && *p != ' ' && wi + 1 < sizeof(word)) word[wi++] = *p++;
      word[wi] = '\0';
      char cand[ASK_QUESTION_MAX + 1];
      if (!line1[0]) snprintf(cand, sizeof(cand), "%s", word);
      else snprintf(cand, sizeof(cand), "%s %s", line1, word);
      if (t.textWidth(cand) <= 292) {
        strncpy(line1, cand, sizeof(line1) - 1);
      } else {
        // overflow -> start line2 with this word + remainder (no mid-word cut)
        snprintf(line2, sizeof(line2), "%s", word);
        // append remaining words to line2 with truncation
        while (*p) {
          while (*p == ' ') p++;
          if (!*p) break;
          wi = 0;
          while (*p && *p != ' ' && wi + 1 < sizeof(word)) word[wi++] = *p++;
          word[wi] = '\0';
          char c2[ASK_QUESTION_MAX + 1];
          snprintf(c2, sizeof(c2), "%s %s", line2, word);
          if (t.textWidth(c2) > 292) break;  // drop the rest (292px budget)
          strncpy(line2, c2, sizeof(line2) - 1);
        }
        break;
      }
    }
    t.setTextColor(COLOR_TEXT, COLOR_BG);
    t.setCursor(13, y0);
    t.print(line1[0] ? line1 : a.question);
    if (line2[0]) {
      t.setCursor(13, y0 + 16);
      t.print(line2);
      return y0 + 32;
    }
    return y0 + 16;
  };

  if (a.count > 3) {
    // 4-option grid: compact card, no preview rows.
    t.drawRoundRect(8, 34, 304, 82, 4, COLOR_EDGE);
    t.fillRoundRect(9, 35, 302, 80, 3, COLOR_BG);
    tiny("OPENCODE ASKS", 13, 38, COLOR_DIM, COLOR_BG);
    drawWrapped(52);
    const int bx[4] = {8, 163, 8, 163}, by[4] = {124, 124, 174, 174};
    for (uint8_t i = 0; i < 4; i++) askButton(bx[i], by[i], 149, 44, a.opts[i].label);
  } else {
    t.drawRoundRect(8, 34, 304, 128, 4, COLOR_EDGE);
    t.fillRoundRect(9, 35, 302, 126, 3, COLOR_BG);
    tiny("OPENCODE ASKS", 13, 38, COLOR_DIM, COLOR_BG);
    int yEnd = drawWrapped(50);
    int detailY = (yEnd <= 66) ? 68 : 84;
    t.setTextFont(2);
    t.setTextColor(COLOR_DIM, COLOR_BG);
    t.setCursor(13, detailY);
    t.print(a.detail[0] ? a.detail : "tap an answer below");
    int hairY = detailY + 18;
    t.drawFastHLine(13, hairY, 294, COLOR_EDGE);
    int y = hairY + 6;
    for (uint8_t i = 0; i < a.count; i++) {
      char row[64];
      snprintf(row, sizeof(row), "%s - %s", a.opts[i].id, a.opts[i].label);
      while (strlen(row) > 1 && t.textWidth(row) > 292) row[strlen(row) - 1] = '\0';
      if (y + 18 > 168) break;  // never collide with button bar
      t.setCursor(13, y);
      t.setTextColor(COLOR_DIM, COLOR_BG);
      t.print(a.opts[i].id);
      t.setTextColor(COLOR_TEXT, COLOR_BG);
      t.print(" ");
      t.print(a.opts[i].label);
      y += 18;
    }
    if (a.count == 2) {
      askButton(8, 172, 149, 48, a.opts[0].label);
      askButton(163, 172, 149, 48, a.opts[1].label);
    } else if (a.count == 1) {
      askButton(ASK_SINGLE_X, ASK_SINGLE_Y, ASK_SINGLE_W, ASK_SINGLE_H, a.opts[0].label);
    } else {
      const int bx3[3] = {8, 111, 214}, bw3[3] = {97, 97, 98};
      for (uint8_t i = 0; i < a.count && i < 3; i++) askButton(bx3[i], 172, bw3[i], 48, a.opts[i].label);
    }
  }
  tiny("TAP TO ANSWER - BOOT = NEXT", 86, 226, COLOR_DIM, COLOR_BG);
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
#ifdef TV154
  // 01+02 only; any stray ASK/other id falls back to overview.
  if (g_screen >= SCR_COUNT) g_screen = SCR_OVERVIEW;
#endif
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
#ifdef TV154
  // TV-154 scope is 01+02 only: ASK never shown, clamp any stray SCR_ASK.
  if (scr >= SCR_COUNT) scr = SCR_OVERVIEW;
#else
  if (scr == SCR_ASK && !g_ask.pending) scr = SCR_OVERVIEW;
#endif
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
#ifdef TV154
      // TV-154 01+02 port: no ASK screen, never auto-popup.
      skipAskIfEmpty(g_screen);
#else
      if (next.pending && (!wasPending || strcmp(next.id, wasId) != 0)) {
        g_screen = SCR_ASK;
      }
      skipAskIfEmpty(g_screen);
#endif
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
#ifdef TV154
  // NM-TV-154: single capacitive touch key T9/GPIO32 (raw < 90 = pressed).
  // Short tap = next screen (01<->02). Hold >5s = wipe WiFi + portal.
  static bool s_tDown = false;
  static unsigned long s_tMs = 0;
  static bool s_tLong = false;
  bool down = touchRead(PIN_TOUCH_T9) < TOUCH_THRESHOLD;
  unsigned long now = millis();
  if (down && !s_tDown) {
    s_tDown = true;
    s_tMs = now;
    s_tLong = false;
  } else if (down && s_tDown && !s_tLong && now - s_tMs > BUTTON_LONG_MS) {
    s_tLong = true;
    WiFi.disconnect(true, true);
    NetConfig cfg = g_cfg;
    // Blocking portal is intentional on explicit long-press only.
    netEnsureWiFi(cfg, true, 0);
    g_cfg = cfg;
    g_lastPoll = 0;
    g_lastAskPoll = 0;
    ESP.restart();
  } else if (!down && s_tDown) {
    if (!s_tLong && (now - s_tMs > 50)) nextScreen();
    s_tDown = false;
  }
#else
  // CYD: BOOT button GPIO0, active LOW.
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
#endif
}

void setup() {
  Serial.begin(SERIAL_BAUD);
#ifdef TV154
  // No BOOT button on NM-TV-154: portal opens on first boot (no creds) or
  // via 5s touch-hold wipe. Never force portal from a floating touch pin.
  bool bootPortal = false;
#else
  pinMode(PIN_BUTTON_BOOT, INPUT_PULLUP);
  bool bootPortal = digitalRead(PIN_BUTTON_BOOT) == LOW;
#endif
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
#ifdef TV154
  // TV-154 01+02 port: keep quota state fresh, never leave 01/02 for ASK.
  skipAskIfEmpty(g_screen);
#else
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
#endif
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
EOF_MAIN

cat > src/diag_main.cpp <<'EOF_DIAG'
// TV-154 power/backlight sweep diagnostic (env: tv154-diag).
// Cycles LCD power rail (GPIO21) x backlight (GPIO19) HIGH/LOW combos,
// re-inits the panel each step, fills a distinct color + logs to serial.
// User reports which color (if any) lights the screen.
#include <Arduino.h>
#include <TFT_eSPI.h>

static TFT_eSPI s_tft;

struct Combo {
  uint8_t pwr;
  uint8_t bl;
  const char *name;
  uint16_t color;
};

static const Combo kCombos[] = {
  {LOW, LOW, "0 PWR-LOW BL-LOW white", TFT_WHITE},
  {LOW, HIGH, "1 PWR-LOW BL-HIGH red", TFT_RED},
  {HIGH, LOW, "2 PWR-HIGH BL-LOW green", TFT_GREEN},
  {HIGH, HIGH, "3 PWR-HIGH BL-HIGH blue", TFT_BLUE},
};

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("[diag] tv154 PWR/BL sweep start (4s per step)");
}

void loop() {
  static int i = 0;
  const Combo &c = kCombos[i % 4];
  pinMode(21, OUTPUT);
  digitalWrite(21, c.pwr);
  pinMode(19, OUTPUT);
  delay(250);  // let the rail settle before panel init
  s_tft.init();
  s_tft.setRotation(0);
  s_tft.invertDisplay(true);
  s_tft.fillScreen(c.color);
  digitalWrite(19, c.bl);
  s_tft.setTextColor(TFT_BLACK, c.color);
  s_tft.drawCentreString(c.name, 120, 110, 2);
  Serial.printf("[diag] step %d: %s rawT9=%d REPORT IF VISIBLE\n", i % 4, c.name,
                touchRead(T9));
  delay(4000);
  i++;
}
EOF_DIAG

fi # end legacy --bootstrap file sync (repo-canonical default skips all cat > above)

echo "=== building ($ENV) in $FW ==="
pio run -e "$ENV"
echo "=== flashing to $PORT (hold BOOT if it fails to connect) ==="
pio run -e "$ENV" -t upload --upload-port "$PORT"
echo "=== DONE ($ENV) ==="
