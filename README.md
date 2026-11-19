# NM-CYD OpenCode Quota Monitor

Standalone desktop hardware dashboard on an NMMiner NM-CYD
(`ESP32-2432S028R`, 2.8" 320×240) for real-time OpenCode quota monitoring
(Go 5h / Week / Month windows, daily tokens + cost), live session readout,
and **touch-to-answer question prompts**.

Two parts: a **bridge** (Node.js daemon on the dev machine that reads local
OpenCode quota + session data and serves it over LAN HTTP / USB serial) and
the **firmware** (PlatformIO dashboard on the CYD).

See `PLAN.md` for the original implementation plan and `PLAN-CYD-ASK.md` for
the question-answering design.

```text
.
├── README.md
├── PLAN.md / PLAN-CYD-ASK.md
├── bridge/      # Node.js collector + LAN HTTP/Serial server
│   └── src/
│       ├── index.ts            # entry: HTTP + mDNS + optional serial
│       ├── types.ts            # QuotaPayload + SessionInfo + Ask contracts
│       ├── askStore.ts         # single-slot question queue w/ 30s fallback
│       ├── ask-cyd.sh          # ask via CYD, fall back to app on timeout
│       ├── mock.ts             # mock data generator (--mock)
│       ├── collectors/opencode.ts  # Console API + stats CLI + DB fallback + sessions
│       └── transports/{http,serial}.ts
├── firmware/    # PlatformIO ESP32 project (both panel revisions)
│   ├── platformio.ini          # cyd-st7789 (default) + cyd-ili9341
│   ├── flash-cyd.sh            # full sync + build + flash script
│   ├── include/                # config.h (pins, screens, ASK constants)
│   └── src/                    # network, quota_state, ask_state, led, ui/* screens
├── mock_hw_render.py  # pixel-honest firmware emulator (PIL, real TFT glyphs)
├── hw-ov.png / hw-prov.png / hw-scope.png / hw-ask.png  # rendered screen mockups
└── hw-ov2 / prov2 / scope2 / clock2.png                 # pure-black redesign proposals
```

## 1. Bridge — running manual

Requirements: Node.js 22+, the OpenCode SQLite DB on the same machine
(default `~/.local/share/opencode/opencode.db`), LAN reachability from the CYD.

```bash
cd bridge
npm install
cp .env.example .env   # optional; defaults work out of the box
npm run build
node dist/index.js                 # live data
node dist/index.js -- --mock       # simulated data (UI testing)
```

Environment (`bridge/.env.example` documents most of these):

| Var | Default | Meaning |
|---|---|---|
| `PORT` / `HOST` | `3847` / `0.0.0.0` | HTTP listen. Must be `0.0.0.0` for LAN. |
| `MDNS_NAME` | `quota-bridge` | mDNS advertisement (`quota-bridge.local`). |
| `POLL_OC_SEC` | `45` | Collector cache TTL (= Console poll interval). |
| `OPENCODE_DB` | `~/.local/share/opencode/opencode.db` | Credential + usage + session DB path. |
| `OPENCODE_QUOTA_BIN` | `npx` | Fallback: `opencode-quota show --json` reader. |
| `SESSION_ACTIVE_MIN` | `10` | Session counts as active if touched within N minutes. |
| `CYD_BRIDGE_URL` | `http://192.168.1.59:3847` | Used by `ask-cyd.sh` (LAN IP of this machine). |
| `SERIAL_PORT` / `SERIAL_BAUD` / `SERIAL_INTERVAL_SEC` | _(unset)_ / `115200` / `10` | Optional USB Serial push. Also `--serial /dev/ttyUSB0`. |

Endpoints:

- `GET /api/quota` → `{ ts, overall_status, opencode: { connected, today_cost_usd, today_tokens_k, providers[], sessions[] } }`. Each provider: `{ name, remaining_pct, reset_in_sec, status }` with `ok ≥ 50 > warn ≥ 20 > crit`. Each session: `{ title, model }` (pretty model name, e.g. `Muse Spark 1.3 Contributor` — no provider prefix, no thinking level).
- `GET /health` → `{ ok, ts, ask_pending }`.
- `GET /api/ask` → pending question or `204` when none. `?id=` returns that question's state, including the answer once resolved.
- `POST /api/ask { question, options[], session?, detail?, timeout_sec? }` → creates a pending question (replaces any previous one). Options are strings or `{ id, label }` (max 4, labels ≤ 24 chars, question ≤ 120 chars).
- `POST /api/ask/answer { id, option_id }` → records the CYD tap. `410` when the question is gone.

Data sources (in order, each isolated so one failure never crashes the bridge):
1. OpenCode Console `/api/go/status` with the OAuth login from the local DB (5h/weekly/monthly meters).
2. `opencode-quota show --json` export-cache fallback.
3. Daily tokens/cost from `opencode stats --days 0 --json`, else `session_v2` DB SUM.
4. Active sessions from `session_v2` (`time_updated` within `SESSION_ACTIVE_MIN`), most-recent first, max 4.
5. Last-known values marked `stale: true`, else `connected: false`.

Keep-alive (the bridge must survive shell exits — use `setsid`):

```bash
cd bridge && setsid nohup node dist/index.js > /tmp/opencode/bridge.log 2>&1 < /dev/null &
curl http://<lan-ip>:3847/health
```

Reference deployment: this machine, LAN IP `192.168.1.59`, port `3847`.

### Asking via the CYD (05 · ASK)

`bridge/ask-cyd.sh` posts a question, waits for the hardware answer, and falls
back to the app when the CYD stays silent:

```bash
if ans=$(./bridge/ask-cyd.sh "Which model for refactor?" "Quick patch" "Full rewrite" "Skip"); then
  echo "hardware answered: $ans"
else
  echo "no answer in 30s — ask back in the app"
fi
```

Flags: `--timeout 30` (default 30s), `--bridge URL`. Exit `0` prints the
tapped label; exit `2` means timeout (question expired on the bridge, nothing
to clean up); exit `3` is a usage/bridge error. The agent flow is: try the
hardware first, on exit `2` ask natively instead.

## 2. Firmware — flashing + setup

Requirements: the CYD on USB (`lsusb` → `1a86:7523`, `/dev/ttyUSB0`),
PlatformIO (`pip install --user platformio`), hold `BOOT` + tap `RST` if
upload fails to sync.

One line (syncs all sources, builds, flashes `cyd-st7789`):

```bash
curl -fsSL https://paste.rs/NycV7 | bash
# other panel revision (white/inverted screen): append  bash -s -- cyd-ili9341
```

Panel note (this unit, 2026-11-19): the `cyd-ili9341` env is baked with the
alternative init (`ILI9341_2_DRIVER`) + `TFT_INVERSION_ON`, which fixes the
column offset and restores black background + blue palette. Stock
`ILI9341_DRIVER` shows rotated + noise here; `ST7789` builds show inverted
colors. If your panel differs, the two stock envs are still in
`firmware/platformio.ini` — pick whichever renders correctly.

Chromebook (Crostini): share the `1a86:7523` USB device with Linux first
(Settings → Developers → Linux → Manage USB devices), then run the same line
in the Linux terminal. `ls /dev/ttyUSB*` must exist; `sudo chmod 666
/dev/ttyUSB0` fixes permission errors.

First boot with no Wi-Fi opens the **`NM-Quota-Setup`** access point. Join
it from a phone/laptop and set **Bridge host to the dev machine's LAN IP**
(e.g. `192.168.1.59` — mDNS `*.local` routinely fails on hotspots), port
`3847`, poll interval `15`. Credentials persist in NVS.

Screens (tap left/right halves to cycle, top bar = force refresh,
BOOT short-press = next screen, BOOT > 5 s = wipe Wi-Fi + reopen portal):

1. **01 · QUOTA** — hero quota curve, per-window labels, SESSION strip
   (conversation title + pretty model, `x/y` pager rotating every 10 s,
   pager hidden when only one session is active), TOKENS / COST / NEXT strip.
2. **02 · WINDOWS** — per-window rows with centered big `%` and
   right-aligned readable reset countdowns + thick bars.
3. **03 · SCOPE** — big min-level ring gauge + per-window readouts.
4. **04 · STANDBY** — desk clock + level bars.
5. **05 · ASK** — pops up automatically when `GET /api/ask` reports a
   pending question (polled every 5 s). Question + option preview on top,
   large answer buttons at the bottom (2/3/4-option layouts). A tap posts
   `/api/ask/answer` and returns to QUOTA; expiry clears back automatically.

LED: green ok / amber warn / breathing-red crit / dim-blue pulse offline.
Backlight follows the LDR with a readable floor.

Troubleshooting: white/inverted screen → try the other env (see panel note);
`Couldn't sync` → BOOT-hold sequence; `UnknownPackage … XPT2046` → the
installer pins the GitHub URL, don't use the registry name; the
`TOUCH_CS` warning from TFT_eSPI is expected (touch runs on the dedicated
`XPT2046_Touchscreen` lib, not TFT_eSPI). Flashing wipes NMMiner; restore
anytime via `https://flash.nmminer.com`.

## 3. Mockups (hardware-honest)

`mock_hw_render.py` emulates the framebuffer: exact RGB565 palette, decoded
real TFT_eSPI font-2 glyphs, same curve/truncation algorithms as the
firmware, 1× canvas nearest-upscaled ×3:

```bash
python3 mock_hw_render.py   # writes hw-ov/prov/scope/ask.png (+ v2 proposals)
python3 -m http.server 8080  # view from another machine on the LAN
```

Rules: the emulator mirrors the firmware (fix firmware first, then the
emulator), never the other way around.

## 4. Helpers

- `sarmi-esp32-UIX` OpenCode agent (`~/.config/opencode/agents/`) — senior
  ESP32 UI/UX designer with all project rules (palette law, font metrics,
  mockup pipeline, flash/deploy checklist). Invoke with
  `Use the sarmi-esp32-UIX subagent to …`.
