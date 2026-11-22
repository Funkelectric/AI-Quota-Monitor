# Changelog

All notable changes to AI Quota Monitor (bridge + CYD/TV-154 firmware).

## [0.3.0] — 2026-11-22 (END OF TASK vs END OF WORK)

Firmware `FW_VERSION` `v0.2` → `v0.3` on both boards. Bridge `0.1.0` → `0.3.0`.
`END OF WORK` stays valid (fully done); `END OF TASK` is the new latched state
for "conversation back to user, N background agents still running".

### Added
- **END OF TASK latch (both boards, same shared screen):** bridge counts busy
  children (`session_v2` `parent_id = <root>`, `time_idle IS NULL`, **plus running shells** (`job` `status='running'`,
  `time_updated`-fresh) and embeds `endofwork.running: N` in `GET /api/quota`
  (`+12 B`, still <150 B). `0` = `END OF WORK` (blinks white ↔ ice-blue);
  `>0` = `END OF TASK` hero (solid ice-blue, no blink) + `N agents still
  running` subline (`1 agent…` singular). Hero+sub centered as one block
  (hero `113..145`, sub `155..171`, center `142`, clearances `25/25` on 240px;
  same law scales to 320px). Per-tick recount flips TASK → WORK (new id)
  when the last agent finishes.
- **Bridge:** `endWorkStore.running_agents` (+ `setRunningAgents` in-place
  recount), watcher fire-time count + TASK→WORK re-fire,
  `POST /api/endofwork { running? }` passthrough. Manual:
  `bridge/endofwork-cyd.sh "Title" ["Model"] [--running N]`.
- **Firmware:** `QuotaState.endwork_running` (+1 B), `running` parse
  (clamped `0..99`), `END - TASK` header override, block-centered TASK layout,
  stale `screens.h` "CYD only" comment fixed (both boards share the latch).
- TV-154 `END OF TASK` mockups: `mock_tv154_endotask_render.py` →
  `mockup-tv154-endotask-ice.png` (reference) / `-white.png` (alt) /
  `-endotask.png` (combo); `PLAN-ENDOFTASK.md` (feasibility + measured audit).

### Changed
- Docs (`README.md`) split END latch into WORK vs TASK, endpoints show
  `running`, Chromebook flash line uses the LAN tarball
  (`curl …/ew.tgz | tar -xz -C ~ && cd ~/firmware && … flash-cyd.sh`).

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
  tarball served from the PiBiatch (no GitHub round-trip needed).

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
