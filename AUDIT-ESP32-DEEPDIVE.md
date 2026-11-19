# ESP32-2432S028R (CYD) Deep-Dive Audit — firmware + bridge

Date: 2026-11-19 · Branch: `audit/esp32-deepdive` · Scope: read-only audit, no code changed.
Tree audited: `firmware/` (PlatformIO, TFT_eSPI, XPT2046, ArduinoJson v7, WiFiManager),
`bridge/` (Node 22, native http, `node:sqlite`, serialport), `mock_hw_render.py`,
`platformio.ini`, `README.md`, `PLAN.md`, `PLAN-CYD-ASK.md`.

## 0. Verdict in one paragraph

Pin map, dual-SPI isolation, active-LOW LED handling and payload-size discipline are
correct and match the CYD single source of truth. The system is shippable for desk use,
but has **5 critical interop/robustness gaps** (Wi-Fi reconnect latch, bridge-latency vs
firmware-timeout mismatch, ASK id-width mismatch, missing Serial ASK path, full-screen
redraw flicker/blocking network on the UI core). All are fixable without hardware or
protocol redesign. Fix plan below is ordered P0 (ship-blockers) → P3 (polish).

## 1. Hardware / config conformance (what is right)

- TFT HSPI pins `13/12/14/33?` — correct: `MOSI 13, MISO 12, SCLK 14, CS 15, DC 2,
  RST -1, BL 21` in `firmware/platformio.ini:19-26` and `firmware/include/config.h:4-10`.
- Touch on dedicated `SPIClass(VSPI)`, `begin(25,39,32,33)` = SCK/MISO/MOSI/CS, correct
  order (`firmware/src/ui/display.cpp:22`), `XPT2046_Touchscreen(CS 33, IRQ 36)`
  (`display.cpp:9`). Bus isolation requirement met.
- RGB LED active-LOW inversion (`255 - brightness`) correct (`led_controller.cpp:4-6`);
  LDR on `GPIO34` (ADC1, Wi-Fi-safe) correct (`config.h:31`, `led_controller.cpp:71`).
- BOOT `GPIO0` `INPUT_PULLUP`, short=next / long>5 s=wipe shape present
  (`main.cpp:91-110`), `BUTTON_LONG_MS 5000` (`config.h:71`).
- JSON size discipline present: `QUOTA_JSON_MAX 2048` / `ASK_JSON_MAX 1024`
  (`config.h:75,84`), static fetch buffers (`network.cpp:89,127`), reused static
  `JsonDocument`s (`quota_state.cpp:52`, `ask_state.cpp:12`).

## 2. Findings — CRITICAL (fix before calling it done)

### C1. Wi-Fi drop latches offline forever — no reconnect path
- `main.cpp:58-67,209-218`: `pollNow`/`pollAskNow` early-return when
  `!netIsConnected()`; loop never calls `netEnsureWiFi` / `WiFi.reconnect()` again.
- `netEnsureWiFi` (`network.cpp:44-86`) is only invoked from `setup()` and the BOOT
  long-press path. A router roam, DHCP expiry, or bridge AP restart leaves the
  dashboard on `WAITING FOR BRIDGE` until manual reboot.
- NTP (`configTzTime`, `network.cpp:83`) is also boot-only, so the clock screen can
  sit at `--:--` indefinitely after a drop.
- Risk: overnight/off-site staleness; user perceives "bridge broken" when it is the
  CYD.

### C2. Bridge worst-case collection time exceeds firmware HTTP timeout
- Firmware: `HTTP_TIMEOUT_MS 8000` (`config.h:57`), applied to quota (`network.cpp:96`)
  and ask (`network.cpp:135`) fetches.
- Bridge `collectOpenCode()` (`bridge/src/collectors/opencode.ts:296-365`) runs
  serially on a cache miss: `getTodayUsage` (exec `opencode stats`, 15 s timeout,
  `:162-169`) → `queryGoStatus` (10 s, `:127-133`) → `readQuotaShowFallback`
  (npx fetch, 20 s, `:218`) ≈ **up to ~45 s** before the HTTP handler
  (`bridge/src/transports/http.ts:55-70`) responds.
- Any cold / CLI-busy / Console-slow poll makes the CYD time out, mark
  `fresh=false`/offline, and flash the blue LED — even though the bridge is healthy.
- Compounds with §C5: two sequential 8 s blocks (quota + ask) already stall the UI
  ~16 s.

### C3. ASK id width mismatch — long ids can never be answered + wrong-answer masking
- Bridge: `id.slice(0,16)` → up to **16 chars** (`bridge/src/askStore.ts:63`); `rid()`
  (`askStore.ts:43-45`) is `q_` + base36 time (~8 ch) + base36 rand (≤3 ch) ≈ 12–14 ch
  today, but unbounded by contract.
- Firmware: `ASK_ID_MAX 15` (`config.h:89`); POST body truncates `"%.15s"`
  (`network.cpp:178`). A 16-char id is truncated on tap → bridge `answerAsk` finds no
  match → `410` (`http.ts:126-128`) → tap silently does nothing.
- Masking bug: `answerAsk` (`askStore.ts:104-114`) falls back to `p.options[0]` on
  unknown `option_id` instead of rejecting, so a truncated/garbled id records the
  **wrong** answer rather than failing loudly.

### C4. Serial/USB ASK path missing on both ends (PLAN-CYD-ASK not implemented)
- `serialPump()` (`main.cpp:70-89`) only tries `parseQuotaPayload`; `{"type":"ask"}`
  frames (planned in `PLAN-CYD-ASK.md §3.1/§5`) have no parser/route.
- `bridge/src/transports/serial.ts:29-46` only pushes quota payload, never ask frames.
- Effect: zero-Wi-Fi desk setups (a supported mode per README) never see `05 · ASK`;
  worse, an ask-shaped line is silently dropped as "quota parse fail".

### C5. Full-screen redraw + blocking polls = flicker and UI stalls
- Every `draw*` starts with `fillScreen` (`screens.cpp:339,355,375,436,492`); hero curve
  (`screens.cpp:266-282`) issues ~918 `fillRect` + ~152 `drawLine` per frame.
- Re-render triggers: quota poll (15 s), ask poll while on ASK (5 s,
  `main.cpp:151-152`), forced refresh, and the 10 s countdown tick
  (`main.cpp:221`). Visible flicker + ~200–400 ms SPI block each time.
- Network calls run synchronously on the loop core: `pollNow` + `pollAskNow`
  back-to-back in `loop()` (`main.cpp:217-218`), `netPostAnswer` inside the touch
  handler (`main.cpp:192-195`), and `netEnsureWiFi(...,0)` (infinite portal) inside
  `buttonTick` (`main.cpp:99-111`). No mutex/task split; LED/backlight/touch all stall.

## 3. Findings — HIGH

### H1. ASK expiry computed but never enforced on-device
- `parseAskPayload` sets `expires_ms` (`ask_state.cpp:32`), but nothing in `main.cpp`
  compares `millis()` against it. On transport error `pollAskNow` early-returns
  (`main.cpp:135`) keeping a stale `pending=true` forever (until a later 204 arrives).
  Offline CYD can display an already-timed-out question indefinitely.

### H2. Providers screen overflows with 4 pools; bridge can send 6
- `drawProviders` steps `y += 64` from `HEADER_H+10=38` (`screens.cpp:362-369`):
  3 pools end at ~222 px (fits); 4th row starts ~230, meter bar lands off-screen.
- Bridge fallback `readQuotaShowFallback` caps at **6** (`opencode.ts:242,244`) while
  firmware `POOLS_MAX 4` (`config.h:79`) silently drops the rest. Cap the bridge at 4
  (or 3) and handle overflow in the UI (scroll / "…+n more").

### H3. Non-ASCII `·` (U+00B7) in TFT_eSPI bitmap fonts
- `screenSection()` (`screens.cpp:19-27`), scope labels (`screens.cpp:425,428`),
  readout code — font1/font2 are 7-bit bitmap fonts; the 2-byte UTF-8 middle dot
  renders as two garbage glyphs on-device (the PIL mock may hide this). Use ASCII
  `-`/`|` for all on-screen strings.

### H4. BOOT button has no debounce and no long-press feedback
- `buttonTick` (`main.cpp:91-110`) triggers `nextScreen()` on any release edge with no
  ~50 ms guard; contact bounce can skip screens. Tribal guardrail also asks for Red-LED
  feedback during the >5 s hold and NVS/credential wipe + `ESP.restart()` semantics;
  current code calls `WiFi.disconnect(true,true)` + blocking portal with a frozen
  display and no LED cue.

### H5. Backlight loop is slow, unfiltered, uncalibrated
- `backlightTick` (`led_controller.cpp:68-77`): single raw `analogRead` per 500 ms, no
  EMA, no deadband/hysteresis (tribal rule), ±1 step per tick → full 40→255 swing
  takes **~107 s**. No `analogSetAttenuation()` / ADC characterisation; the
  `map(raw,200,3500,…)` range is an assumption. Expect dither flicker near thresholds
  and sluggish response walking room-to-room.

### H6. `platformio.ini` reproducibility / panel-correctness gaps
- `platform = espressif32` floating (`platformio.ini:10`) — Arduino core v2 vs v3
  changes `analogWrite`/LEDC behaviour silently. Pin to a tested version.
- `board_build.partitions = huge_app.csv` (`platformio.ini:12`) removes OTA; every
  future update needs USB. Fine if intentional — document it.
- `SPI_FREQUENCY=40000000` for both envs: ILI9341 is typically specced ~30 MHz max
  write; marginal panels glitch/tear at 40 MHz. Consider 27 MHz on the ILI9341 env.
- No `-D TOUCH_CS=-1`: TFT_eSPI touch stays at defaults; harmless today (touch code
  excluded when undefined) but the README-blessed `TOUCH_CS` warning should be killed
  explicitly. `CYD_ST7789` / `CYD_ILI9341_DRIVER` build flags are defined but never
  read by code — dead, remove or use for `#ifdef` panel quirks.
- No `TFT_RGB_ORDER` note: red/blue swap on some ST7789Vs is fixed by RGB/BGR order,
  not just `TFT_INVERSION_ON`. Keep both flags documented per-revision.

### H7. Bridge stale-cache retry storms
- On total failure with a prior cache, `collectOpenCode` returns a merged stale object
  **without** updating `cache.at` (`opencode.ts:346-356`). Every subsequent
  `GET /api/quota` (CYD every 15 s + serial every 10 s) re-runs the full ≤45 s chain.
  Add backoff: refresh `cache.at` on stale serve or serve last-good immediately and
  refresh in background.

### H8. ASK navigation traps
- `nextScreen/prevScreen` (`main.cpp:48-56`) cycle all 5 screens, so the user can land
  on `SCR_ASK` with `!pending` → bare `NO QUESTION` (`screens.cpp:495-498`).
  Skip ASK when nothing is pending (both directions + auto-return on expiry/answer).

### H9. Touch accuracy / edge reliability
- Calibration `TOUCH_RAW_{X,Y}_MIN/MAX 240/3800` (`config.h:21-24`) is symmetric guess
  values; `touchTap` (`display.cpp:30-55`) maps full-frame then flips for rotation 3.
  Resistive edges drift; ASK buttons start at x=8 / end at 312 with 6 px gaps —
  expect edge misses. `touched()` pressure threshold is library-default, never tuned;
  `getPoint()` is read only on release (post-lift coordinates can stale-read).
  Keep `MARGIN 8` + ≥44 px targets (already true) and add a calibration/validation pass.

## 4. Findings — MEDIUM / LOW

- **M1.** `wasId` points into `g_ask.id` across `g_ask = next` (`main.cpp:137-144`).
  Works today (compare happens before overwrite) but fragile — copy to a local `char[]`.
- **M2.** `netFetchQuota/Ask` manual stream loop (`network.cpp:109-117,153-161`) trusts
  `getSize()`; chunked (`-1`) bodies rely on the 1.5 s stall heuristic. Prefer
  `http.getString()` with a length guard, or check `Content-Length` ≤ max first.
- **M3.** `configLoad` uses Arduino `String` for NVS (`network.cpp:19-20`) — boot-only,
  acceptable, but replace with `getBytes`/`getString` into `char[]` per SRAM rules.
- **M4.** `static JsonDocument g_doc / g_askDoc` are unbounded dynamic pools (v7);
  prefer `StaticJsonDocument<2048/1024>` (or fixed-capacity `JsonDocument`) for soak
  stability + add a `Serial.printf("heap=%u")` soak log.
- **M5.** `drawClock` uses font6 × `setTextSize(2)` (`screens.cpp:448-451`) — ~92 px
  glyphs; verify `HH:MM` fits 320 px on-device (mock uses DejaVu, not the real TFT
  glyphs). `drawScope` center `%` + `rightPair` overlap risk at 3 providers already
  handled by the x=180 anchor — keep.
- **M6.** Single-line question truncation (`screens.cpp:505-508,518-521`) chops 120-char
  questions mid-word; wrap to 2 lines. Single-option ask renders one left-aligned
  97 px button (`screens.cpp:547-549` + `askHit`, `main.cpp:171-176`) — centre it.
- **M7.** `fmtCountdown` shows `0m` under 60 s (`quota_state.cpp:13-15`); show seconds
  (`45s`) below 2 min.
- **M8.** Security posture is LAN-open by design (CORS `*` in `http.ts:53`, no
  `CYD_TOKEN`, open `POST /api/ask`, open Wi-FiManager AP). Acceptable for a desk toy
  — document it; add optional bearer token (already proposed in PLAN-CYD-ASK §3.2).
- **M9.** `.env.example` carries dead `POLL_AG_SEC` (antigravity leftover); bridge
  `SESSION_ACTIVE_MIN` default 10 matches README. `ask-cyd.sh` initial `curl` is
  unguarded under `set -e` (bridge down → exit path unclear); poll loop `sleep 2` vs
  `curl --max-time 10` can overlap — harmless, tidy anyway.
- **M10.** `getRecentSessions` (`opencode.ts:254-294`) always passes the
  `filter(s => s.title || s.model)` since title defaults to `"untitled"` — stale
  untitled sessions display. Filter on recency only (already) + drop `"untitled"`?
  Product call.
- **M11.** `flash-cyd.sh` (1643 lines, embeds full file copies) **overwrites local
  edits** on every run and duplicates `firmware/` sources. Keep the script as a
  bootstrap, but make the repo files canonical and the script sync-check instead of
  clobber.
- **M12.** Power: no brownout handling; full-bright backlight at boot + Wi-Fi TX peaks
  on marginal USB cables = classic CYD brownout/reboot. Short cable / powered hub
  note belongs in README troubleshooting.

## 5. Fix & optimisation plan (prioritised)

### P0 — correctness / ship-blockers
1. **Reconnect + NTP recovery.** `WiFi.setAutoReconnect(true)` in setup; in `loop()`,
   when `!netIsConnected()` attempt periodic `WiFi.reconnect()`/portal-light
   re-associate (non-blocking, e.g. every 30 s) and re-run `configTzTime` on regain.
   Rationale: fixes C1, the most visible "dead dashboard" failure.
2. **Bound bridge latency below the 8 s firmware budget.** Either (a) shorten
   collector timeouts (`stats` 15 s→5 s, quota-show 20 s→8 s) and race with cache, or
   (b, better) serve last-good/stale **immediately** and refresh in background on a
   `POLL_OC_SEC` timer instead of per-request collection. Rationale: fixes C2 without
   touching firmware timing.
3. **Unify ASK id width at 31.** Bump `ASK_ID_MAX` to 31, POST `%.31s`, bridge slice
   to 31; add a contract test (`q` + 29 alnum). Change `answerAsk` unknown-id fallback
   to `410`, not `options[0]`. Rationale: fixes C3 + wrong-answer masking.
4. **Implement Serial ASK or officially drop it.** Either add the `{"type":…}` envelope
   on `serial.ts` + route in `serialPump`, or document USB-mode as quota-only and
   remove the PLAN claim. Rationale: C4 is a documented-but-absent feature.
5. **De-block the UI core.** Move quota+ask fetches off the touch path: poll on timers
   only, never inside `touchTap`/`buttonTick`; show a `SYNC…` indicator instead of
   freezing. Split `pollNow`/`pollAskNow` so a slow quota fetch can't delay ask
   (and vice versa). Rationale: fixes C5 stalls/WDT risk.

### P1 — robustness (next pass)
6. Enforce `expires_ms` in `loop()`; on expiry clear `pending` and auto-return from ASK.
7. Debounce BOOT (~50 ms), add Red-LED long-press feedback, and after wipe call
   `ESP.restart()` per tribal spec (verify portal re-opens post-restart).
8. Skip `SCR_ASK` in screen cycling when `!pending`; auto-return on answer/timeout
   (partially present — complete it).
9. Cap bridge providers to 4 (match `POOLS_MAX`) and fix `drawProviders` for the 4th
   row (tighter `y` step or 2-line condensed rows).
10. Replace `·` with ASCII in all firmware strings; re-render `mock_hw_render.py` to
    match (emulator follows firmware, per README rule).
11. EMA + deadband + faster slew for backlight (`±8`/tick, 3–5 sample EMA,
    `analogSetAttenuation(ADC_11db)` explicitly); keep the ≥40 floor.

### P2 — platform / performance
12. Pin `espressif32` platform version; document `huge_app.csv` = no-OTA tradeoff;
    drop ILI9341 SPI to 27 MHz; add `-D TOUCH_CS=-1`; remove-or-use `CYD_*` flags;
    document `TFT_RGB_ORDER` per revision.
13. Reduce redraw cost: redraw hero panel only on data change; 10 s tick updates only
    header/countdown regions (or small `TFT_eSprite` tiles); add `ESP.getFreeHeap()`
    periodic log for soak validation.
14. `StaticJsonDocument` pools; eliminate `String` in `configLoad`; use `getString`
    into stack buffers.
15. Touch pass: pressure-threshold tune, edge-margin validation on-device, optional
    3-point calibration constants per unit.

### P3 — polish / docs
16. Two-line question wrap; centred single-option button; `45s`-style sub-minute
    countdowns; drop `"untitled"` sessions or show `—`.
17. Optional `CYD_TOKEN` bearer on bridge + firmware header; document LAN-open default.
18. Clean `.env.example` (`POLL_AG_SEC` removal), harden `ask-cyd.sh` curl guards.
19. Make `flash-cyd.sh` non-clobbering (diff-check, or generate from repo files).

## 6. Verification steps (no code changed in this audit)

```bash
# firmware builds — both panel revisions must pass with zero errors
cd firmware
pio run -e cyd-st7789
pio run -e cyd-ili9341

# optional: static sanity (no hardware needed)
pio check -e cyd-st7789 --flags "--std=c++17" 2>/dev/null || true

# bridge typecheck + mock smoke
cd ../bridge
npm run build
node dist/index.js -- --mock &
curl -s localhost:3847/api/quota | head -c 600; echo
curl -s localhost:3847/health; echo
curl -s -X POST localhost:3847/api/ask \
  -H 'Content-Type: application/json' \
  -d '{"question":"Which model?","options":["Quick","Full","Skip"],"timeout_sec":30}'
curl -s "localhost:3847/api/ask?id=<qid>"; echo
kill %1

# on-device checks (need /dev/ttyUSB0, hold BOOT+tap RST if sync fails)
pio run -e cyd-st7789 -t upload --upload-port /dev/ttyUSB0
# 1. watch boot log @115200: free heap stable over 1 h soak
# 2. unplug AP for 60 s → replug → dashboard recovers without reboot (C1)
# 3. cold bridge (kill collectors) → quota screen updates <8 s (C2)
# 4. POST 16-char-id ask → tap answers 200, never 410 (C3)
# 5. USB serial mode → quota renders; ask behaviour matches docs (C4)
# 6. tap L/R halves + header + BOOT short/long; edge-button hit rate (H9)
# 7. cover LDR → backlight dims smoothly, never black; uncover → brightens <5 s (H5)
python3 mock_hw_render.py  # emulator must match firmware after P1-10
```

## 7. File index (for follow-up work)

- Pins/config: `firmware/platformio.ini:8-68`, `firmware/include/config.h:4-33`,
  `firmware/include/ui_theme.h:4-21`
- Boot/loop/touch/button/serial: `firmware/src/main.cpp:70-230`
- Net: `firmware/src/network.{h,cpp}` (fetch `network.cpp:91-182`)
- State/parse: `firmware/src/quota_state.{h,cpp}`, `firmware/src/ask_state.{h,cpp}`
- UI: `firmware/src/ui/display.{h,cpp}`, `firmware/src/ui/screens.cpp` (hero
  `247-303`, providers `353-370`, scope `372-432`, clock `434-469`, ask `490-552`)
- LED/BL: `firmware/src/led_controller.{h,cpp}`
- Bridge: `bridge/src/index.ts`, `transports/http.ts`, `transports/serial.ts`,
  `collectors/opencode.ts`, `askStore.ts`, `types.ts`, `mock.ts`, `ask-cyd.sh`
