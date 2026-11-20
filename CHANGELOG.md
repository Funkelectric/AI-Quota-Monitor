# Changelog

All notable changes to AI Quota Monitor (bridge + CYD/TV-154 firmware).

## [0.2.0] — 2026-11-20 (CYD + TV-154 END OF WORK)

Branch `feature/endofwork` (merged). Firmware `FW_VERSION` `v0.1` → `v0.2` on both boards.

### Added
- **END - WORK latch screen (CYD 320x240):** pops when the current work ends,
  stays until any screen touch. Shows the ended-work title + model and a
  single centered `END OF WORK` hero blinking white ↔ ice-blue (2 s tick +
  every poll). Button outline pulses in phase. Dismiss posts
  `POST /api/endofwork/dismiss` to clear the bridge slot.
- **ASK takes precedence:** a new question pops 05 · ASK even over a latched
  END OF WORK; answering/expiry falls back to END OF WORK while its event
  is still live.
- **Bridge `endofwork` API:** `GET /api/endofwork` (200/204),
  `POST /api/endofwork {title, model?, session?}`,
  `POST /api/endofwork/dismiss {id}`, pending event embedded in
  `GET /api/quota` as `endofwork: {id, title, model, ended_at}` (no extra
  poll needed — rides quota + USB-serial frames). `/health` gains
  `endwork_pending`. New `bridge/endWorkStore.ts`, `bridge/endofwork-cyd.sh`.
- **Automatic firing:** bridge watches OpenCode `session_v2` every 5 s and
  latches END OF WORK when a root conversation's `time_idle` advances past
  `time_busy` (i.e. directly when it gives back control to the user).
  Subagents excluded via `parent_id`; first poll only seeds the baseline.
  New `bridge/src/collectors/endWorkWatcher.ts` (`ENDWORK_WATCH`,
  `ENDWORK_WATCH_SEC`).
- 1:1 CYD + TV-154 END OF WORK mockups (`mock_endofwork_render.py`,
  `mock_tv154_endofwork_render.py`); LAN-tarball Chromebook flash flow.
- **TV-154 port:** same event drives an `END - WORK` latch on 240px
  (`SCR_ENDWORK 2`, `SCR_COUNT 3`, no ASK screen): top-key tap dismisses,
  shared `drawEndWork()` with `LAYOUT_W`-relative geometry, same v0.2.
  Mock + `tv154-st7789` build verified.

### Fixed
- Hero text blank on ILI9341 panels: font 6 draws digits but not letters on
  that build, so the hero uses font 2 scaled (auto-fit 3→2) with `print()`.
- `setTextSize(1)` + datum reset forced on ENDWORK entry (clock screen
  leaked size 2/datum), serial latch logging added.
- `paste.rs` outage: Chromebook one-liner moved to catbox, then to a LAN
  tarball served from the bridge host (no GitHub round-trip needed).

## [0.1.0] — 2026-11-19 / 2026-11-20

Initial release: standalone desktop OpenCode quota dashboard.

### Added
- **Bridge** (`bridge/`): `GET /api/quota` (Go 5h/Week/Month meters via
  OpenCode Console OAuth + `opencode-quota` fallback + `session_v2` SUM),
  `GET /api/ask`, `POST /api/ask`, `POST /api/ask/answer`,
  `GET /health`, mDNS, optional USB-serial push, mock mode, `ask-cyd.sh`.
- **CYD firmware** (`firmware/`, envs `cyd-st7789` / `cyd-ili9341`):
  01 QUOTA (hero curve, session rotator strip, TOKENS/VER/NEXT strip),
  02 PROVIDERS, 03 SCOPE (vectorscope ring), 04 STANDBY (desk clock),
  05 ASK (touch-answer buttons, auto-popup, expiry, deferred POST).
  XPT2046 touch (L/R = screens, top bar = refresh), BOOT = next / 5 s hold =
  wipe Wi-Fi + portal, RGB LED status, LDR auto-backlight, non-blocking
  Wi-Fi reconnect + NTP regain, `FW_VERSION v0.1` in VER strip.
- **TV-154 port** (`tv154-st7789`, 240×240 ST7789/HSPI, `tv154-diag` sweep):
  01 QUOTA + 02 WINDOWS only, single top key, fixed backlight, same bridge.
- `firmware/flash-cyd.sh` one-shot build+flash, hardware-honest mock
  renderers, audit + deep-dive docs, README with screenshots.
