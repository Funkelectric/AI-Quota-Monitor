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
// TV-154 scope: 01 QUOTA + 02 WINDOWS + END - WORK latch (no ASK screen,
// single top key dismisses the latch).
#define SCR_ENDWORK   2
#define SCR_COUNT     3
#define HAS_XPT2046   0
#else
#define SCR_ENDWORK   5
#define SCR_COUNT     6
#define HAS_XPT2046   1
#endif

// Network / bridge defaults
#define WIFI_AP_NAME "AI-Quota-Setup"
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

// Firmware version shown in the readout strip (VER field), both hardware.
#define FW_VERSION "v0.2"

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

// END - WORK screen: latched event embedded in the quota payload
// ("endofwork": {id, title, model, ended_at}). No extra poll needed —
// quota poll + USB-serial quota frames carry it. Touch dismisses locally
// and POSTs /api/endofwork/dismiss to clear the bridge slot.
#define ENDWORK_ID_MAX 31
#define ENDWORK_TITLE_MAX 23
#define ENDWORK_MODEL_MAX 31

// WiFi reconnect: non-blocking re-associate attempt every 30s when offline.
// Fixes C1 (drop latched offline forever). NTP re-synced on regain.
#define WIFI_RECONNECT_SEC 30
#define WIFI_RECONNECT_MS (WIFI_RECONNECT_SEC * 1000UL)

// Backlight: EMA + deadband + fast slew (fixes H5 slow 107s swing).
#define BL_EMA_N 4
#define BL_SLEW_STEP 8
#define BL_DEADBAND 4
