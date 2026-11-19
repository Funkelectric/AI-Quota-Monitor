# Implementation Plan: NM-CYD Antigravity & OpenCode Quota Monitor

> **Target Usage**: Drop this `PLAN.md` into your project workspace in **Antigravity IDE** and instruct the agent to execute it phase by phase.

---

## 1. Project Overview

Transform an **NMMiner NM-CYD** (`ESP32-2432S028R`, 2.8" Cheap Yellow Display) from a solo BTC lottery miner into a standalone desktop hardware dashboard that monitors real-time AI coding quotas for **Google Antigravity IDE** and **OpenCode**.

### Why a Two-Part Architecture?
An ESP32 cannot directly inspect local OS processes (Antigravity's local Language Server) or read local developer credentials/SQLite logs (OpenCode). Therefore, the system consists of:
1. **Local Quota Bridge (`bridge/`)**: A lightweight Node.js/TypeScript daemon running on your dev machine that collects Antigravity & OpenCode quotas and exposes a unified, compact JSON payload over **LAN HTTP** (and optionally **USB Serial**).
2. **NM-CYD Firmware (`firmware/`)**: A PlatformIO + Arduino/LVGL firmware flashed onto the ESP32-2432S028R that renders a 320×240 dark-mode dashboard, supports touch navigation, and uses the onboard RGB LED + light sensor for ambient status alerts and auto-dimming.

> **Hardware Recovery Note**: Flashing custom firmware to the NM-CYD is reversible. Per NMTech documentation, the original NMMiner firmware and its built-in license can be restored anytime via `https://flash.nmminer.com`.

---

## 2. Target Hardware Specifications (`ESP32-2432S028R`)

| Component | Specification / Pinout | Notes for Agent |
| :--- | :--- | :--- |
| **MCU** | ESP32-WROOM-32 (Dual-core 240 MHz, 520 KB SRAM, 4 MB Flash) | Wi-Fi 2.4 GHz (802.11 b/g/n) + BLE |
| **Display** | 2.8" TFT LCD, 240×320 (Landscape: `320×240`) | **CRITICAL**: NM-CYD ships with either **ST7789** (default on newer USB-C units) or **ILI9341**. Build *both* PlatformIO environments. |
| **Display SPI** | `MOSI=13`, `MISO=12`, `SCLK=14`, `CS=15`, `DC=2`, `RST=-1`, `BL=21` | Backlight (`GPIO 21`) supports PWM dimming. |
| **Touchscreen** | XPT2046 Resistive Touch (`CLK=25`, `MOSI=32`, `MISO=39`, `CS=33`, `IRQ=36`) | Uses a separate SPI bus from the display. |
| **RGB LED** | `R=4`, `G=16`, `B=17` (**Active LOW**) | Use for ambient quota health indicator (Green/Yellow/Red). |
| **Light Sensor** | LDR on `GPIO 34` (ADC) | Optional auto-brightness control. |
| **User Button** | `BOOT` button on `GPIO 0` | Fallback to cycle screens / trigger config portal. |
| **USB Interface** | USB-C (CH340 UART) | Used for power, flashing, and optional USB Serial data push. |

---

## 3. System Architecture & Data Contract

```text
┌──────────────────────────────────────────────────────────┐
│                  Developer Workstation                   │
│                                                          │
│  [Antigravity IDE] ──(Local LS + CSRF)──┐                │
│                                         ▼                │
│  [OpenCode CLI/DB] ──(Plugin/CLI/FS)──► [Quota Bridge]   │
│                                         (Node.js / TS)   │
└──────────────────────────────────────────┬───────────────┘
                                           │
                      HTTP JSON (Wi-Fi LAN)│  OR  USB Serial (115200)
                                           ▼
┌──────────────────────────────────────────────────────────┐
│              NM-CYD (ESP32-2432S028R)                    │
│  • 320x240 LVGL / TFT_eSPI Dark Dashboard                │
│  • Touch / BOOT button screen switching                  │
│  • RGB LED ambient alert (Green / Yellow / Red)          │
│  • Auto-dimming via LDR (GPIO 34)                        │
└──────────────────────────────────────────────────────────┘
```

### Unified JSON Schema (`GET /api/quota`)
Keep the payload compact (< 2 KB) so `ArduinoJson` parses it reliably within ESP32 SRAM constraints.

```json
{
  "ts": 1795050000,
  "overall_status": "ok",
  "antigravity": {
    "connected": true,
    "active_model": "Gemini 3.1 Pro",
    "pools": [
      {
        "name": "Gemini Pro",
        "remaining_pct": 82,
        "reset_in_sec": 14400,
        "status": "ok"
      },
      {
        "name": "Claude",
        "remaining_pct": 34,
        "reset_in_sec": 7200,
        "status": "warn"
      }
    ]
  },
  "opencode": {
    "connected": true,
    "today_cost_usd": 1.42,
    "today_tokens_k": 485,
    "providers": [
      {
        "name": "OpenCode Go",
        "remaining_pct": 65,
        "reset_in_sec": 10800,
        "status": "ok"
      },
      {
        "name": "Anthropic",
        "remaining_pct": 18,
        "reset_in_sec": 3600,
        "status": "crit"
      }
    ]
  }
}
```

**Status Thresholds**:
- `ok`: `remaining_pct >= 50` (Green)
- `warn`: `20 <= remaining_pct < 50` (Yellow/Amber)
- `crit`: `remaining_pct < 20` (Red)

---

## 4. Proposed Repository Structure

```text
cyd-quota-monitor/
├── PLAN.md
├── README.md
├── bridge/                         # Local Collector & HTTP/Serial Server
│   ├── package.json
│   ├── tsconfig.json
│   ├── .env.example
│   └── src/
│       ├── index.ts                # Entry point (HTTP server + mDNS + optional Serial)
│       ├── types.ts                # Unified QuotaPayload TypeScript interfaces
│       ├── collectors/
│       │   ├── antigravity.ts      # Local Antigravity Language Server discovery & polling
│       │   └── opencode.ts         # OpenCode quota collector (CLI / plugin export / fallback)
│       ├── transports/
│       │   ├── http.ts             # Express/Fastify or native Node HTTP (/api/quota, /health)
│       │   └── serial.ts           # Optional USB-C newline-delimited JSON pusher
│       └── mock.ts                 # Mock data generator for UI testing without live IDEs
└── firmware/                       # PlatformIO ESP32 Project
    ├── platformio.ini              # Targets: cyd-st7789 (default) & cyd-ili9341
    ├── include/
    │   ├── config.h                # Pins, thresholds, refresh intervals
    │   └── ui_theme.h              # Dark-mode palette & fonts
    └── src/
        ├── main.cpp                # Setup, Wi-Fi/Serial loop, button & LDR handling
        ├── network.cpp             # WiFiManager captive portal + HTTP client + NVS config
        ├── quota_state.h/.cpp      # ArduinoJson parser & state store
        ├── led_controller.cpp      # Active-low RGB LED status + breathing alert
        └── ui/
            ├── display.cpp         # TFT_eSPI + XPT2046 init & backlight PWM
            ├── screen_overview.cpp # Split Antigravity + OpenCode summary view
            ├── screen_ag.cpp       # Detailed Antigravity model pools view
            ├── screen_oc.cpp       # Detailed OpenCode providers + token/cost view
            └── screen_clock.cpp    # Standby/offline desk clock view
```

---

## 5. Phased Implementation Tasks

### Phase 1: Scaffold & Mock Bridge
- [ ] Initialize monorepo structure (`bridge/` and `firmware/`).
- [ ] In `bridge/`, set up TypeScript (`tsx` / `tsup` or `tsc`), define `types.ts` matching the Unified JSON Schema.
- [ ] Implement `src/mock.ts` to simulate dynamic quota drain, reset countdowns, and `ok` / `warn` / `crit` transitions.
- [ ] Implement `src/transports/http.ts` serving `GET /api/quota` and `GET /health` on port `3847` (configurable via `.env`), bound to `0.0.0.0` for LAN access.
- [ ] Add mDNS advertisement (`quota-bridge.local`) so the ESP32 can discover the bridge without hardcoded IPs.
- [ ] **Verification**: Run `npm run dev -- --mock` and confirm `curl http://localhost:3847/api/quota` returns valid JSON under 2 KB.

### Phase 2: Antigravity & OpenCode Collectors
- [ ] **Antigravity Collector (`src/collectors/antigravity.ts`)**:
  - Discover the running local Antigravity Language Server process (cross-platform: macOS/Linux via `ps`/`lsof`, Windows via PowerShell/WMI) to extract the local port and CSRF token.
  - Query the local Antigravity quota endpoint every 15 seconds.
  - Normalize active model, per-pool remaining percentages, and reset timers into the `antigravity` schema block.
  - Handle IDE-closed / unreachable states gracefully (`connected: false`, retain last known values with stale flag).
- [ ] **OpenCode Collector (`src/collectors/opencode.ts`)**:
  - Support primary integration via `@slkiser/opencode-quota` (running `npx @slkiser/opencode-quota@latest show` or reading its configured export/cache JSON file if enabled) **and/or** reading local OpenCode usage storage (`~/.local/share/opencode` / `~/.config/opencode`).
  - Parse provider quota percentages, reset windows, and daily token/cost metrics into the `opencode` schema block.
  - Poll every 30–60 seconds with error isolation so a failing provider does not crash the bridge.
- [ ] **Optional USB Serial Transport (`src/transports/serial.ts`)**:
  - Add an optional `--serial /dev/ttyUSB0` (or `COMx`) flag using `serialport` that pushes a single-line JSON frame every 10 seconds for zero-Wi-Fi desk setups.
- [ ] **Verification**: Run the bridge against live Antigravity and OpenCode sessions; verify JSON output matches actual IDE/TUI quota numbers.

### Phase 3: ESP32 Firmware Core & Hardware Drivers
- [ ] Create `firmware/platformio.ini` using `espressif32` + `arduino` framework with libraries:
  - `bodmer/TFT_eSPI` (configured via `build_flags` so no manual `User_Setup.h` editing is needed)
  - `PaulStoffregen/XPT2046_Touchscreen` (or `TFT_eSPI` / dedicated SPI instance for touch)
  - `bblanchon/ArduinoJson` (v7)
  - `tzapu/WiFiManager`
- [ ] Define **two build environments** in `platformio.ini`:
  - `[env:cyd-st7789]` (ST7789 driver, landscape `320x240`, `TFT_INVERSION_ON` toggleable)
  - `[env:cyd-ili9341]` (ILI9341 driver, landscape `320x240`)
- [ ] Implement `WiFiManager` captive portal (`NM-Quota-Setup` AP) with custom parameters for **Bridge Host/IP** (default `quota-bridge.local`), **Port** (`3847`), and **Poll Interval** (`15s`), persisted in ESP32 `Preferences` (NVS).
- [ ] Implement `quota_state.cpp` to fetch `GET /api/quota` over HTTP (or parse newline-delimited JSON from `Serial` if USB mode is active) and safely update the state struct.
- [ ] Implement `led_controller.cpp` (active-low PWM on GPIOs `4, 16, 17`) and LDR auto-brightness on `GPIO 34` → `GPIO 21`.
- [ ] **Verification**: Compile both `pio run -e cyd-st7789` and `pio run -e cyd-ili9341` with zero errors.

### Phase 4: 320×240 Dashboard UI & Interactivity
- [ ] Design a crisp, high-contrast dark theme (`#0D1117` background, `#161B22` cards, `#3FB950` Green, `#D29922` Amber, `#F85149` Red) optimized for 2.8" readability from arm's length.
- [ ] Implement 4 screens with flicker-free sprite/partial redraws:
  1. **Overview Screen (Default)**:
     - Top status bar: Wi-Fi/USB icon, sync timestamp, overall health dot.
     - Upper card: **Antigravity** (active model badge + top 2–3 pool progress bars + shortest reset timer).
     - Lower card: **OpenCode** (top 2–3 provider bars + today's `$` cost / token count).
  2. **Antigravity Detail Screen**: All Antigravity model pools with exact `%` remaining and `Xh Ym` reset countdowns.
  3. **OpenCode Detail Screen**: All OpenCode providers, daily token count, and cost breakdown.
  4. **Standby / Offline Screen**: Clean digital desk clock + "Bridge Offline / Waiting for IDE" indicator when both tools are disconnected.
- [ ] Wire **Touchscreen** (tap left/right halves to cycle screens, tap top bar to force refresh) and **`BOOT` button (`GPIO 0`)** (short press: next screen; long press > 5s: reset Wi-Fi & open config portal).
- [ ] **Verification**: Flash to NM-CYD, connect to mock bridge, verify all 4 screens, touch cycling, RGB LED color transitions, and graceful offline handling.

### Phase 5: Polish & Auto-Start
- [ ] Add OS background service templates in `bridge/scripts/` (`launchd` plist for macOS, `systemd` user unit for Linux, PowerShell/Task Scheduler script for Windows) so the Quota Bridge starts automatically on login.
- [ ] Write a clear `README.md` covering CH340 driver setup, picking `cyd-st7789` vs `cyd-ili9341`, flashing instructions, and troubleshooting white-screen / inverted-color issues.

---

## 6. Known Hardware & Integration Gotchas (Reference for Agent)

1. **White Screen or Inverted Colors on NM-CYD**:
   - The `ESP32-2432S028R` has two hardware revisions (`ST7789` vs `ILI9341`). Always keep both PlatformIO environments ready and document `TFT_INVERSION_ON` / `TFT_RGB_ORDER` flags.
2. **Touch SPI Bus Conflict**:
   - On the CYD, the TFT uses `HSPI` (`12/13/14/15`) and the XPT2046 touch controller uses separate pins (`25/32/33/36/39`). Do **not** share the display SPI bus with the touch driver—instantiate a dedicated `SPIClass(VSPI)` for touch.
3. **RGB LED Logic**:
   - The onboard RGB LED is **common-anode (active LOW)**: `analogWrite(pin, 255)` is OFF, `analogWrite(pin, 0)` is full brightness.
4. **Firewall / LAN Discovery**:
   - Ensure the bridge listens on `0.0.0.0` (not `127.0.0.1`) and document allowing port `3847/tcp` through the local OS firewall.
5. **ESP32 Heap Stability**:
   - Avoid `String` concatenation loops and dynamic `DynamicJsonDocument` allocations on every poll. Reuse a static buffer / `JsonDocument` and monitor `ESP.getFreeHeap()` over serial during soak testing.