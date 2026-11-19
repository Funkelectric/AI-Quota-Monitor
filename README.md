# NM-CYD OpenCode Quota Monitor

Standalone desktop hardware dashboard on an NMMiner NM-CYD
(`ESP32-2432S028R`, 2.8" 320×240) for real-time OpenCode quota monitoring
(Go 5h / Week / Month windows, daily tokens + cost).

Two parts: a **bridge** (Node.js daemon on the dev machine that reads local
OpenCode quota data and serves it over LAN HTTP / USB serial) and the
**firmware** (PlatformIO dashboard on the CYD).

See `PLAN.md` for the original implementation plan.

```text
.
├── README.md
├── PLAN.md
├── bridge/      # Node.js collector + LAN HTTP/Serial server
│   └── src/
│       ├── index.ts            # entry: HTTP + mDNS + optional serial
│       ├── types.ts            # QuotaPayload contract (< 2 KB JSON)
│       ├── mock.ts             # mock data generator (--mock)
│       ├── collectors/opencode.ts  # Console API + stats CLI + DB fallback
│       └── transports/{http,serial}.ts
├── firmware/    # PlatformIO ESP32 project (both panel revisions)
│   ├── platformio.ini          # cyd-st7789 (default) + cyd-ili9341
│   ├── flash-cyd.sh            # full sync + build + flash script
│   ├── include/                # config.h (pins), ui_theme.h (palette)
│   └── src/                    # network, quota_state, led, ui/* screens
├── mock_hw_render.py  # pixel-honest firmware emulator (PIL, real TFT glyphs)
├── hw-ov.png / hw-prov.png / hw-scope.png  # rendered screen mockups
└── mockup-quota-overview.{svg,png}          # original design mockup
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

Environment (`bridge/.env.example` documents all of these):

| Var | Default | Meaning |
|---|---|---|
| `PORT` / `HOST` | `3847` / `0.0.0.0` | HTTP listen. Must be `0.0.0.0` for LAN. |
| `MDNS_NAME` | `quota-bridge` | mDNS advertisement (`quota-bridge.local`). |
| `POLL_OC_SEC` | `45` | Collector cache TTL (= Console poll interval). |
| `OPENCODE_DB` | `~/.local/share/opencode/opencode.db` | Credential + usage DB path. |
| `OPENCODE_QUOTA_BIN` | `npx` | Fallback: `opencode-quota show --json` reader. |
| `SERIAL_PORT` | _(unset)_ | e.g. `/dev/ttyUSB0`: push JSON frames over USB. Also `--serial /dev/ttyUSB0`. |
| `SERIAL_BAUD` / `SERIAL_INTERVAL_SEC` | `115200` / `10` | Serial push settings. |

Endpoints:

- `GET /api/quota` → `{ ts, overall_status, opencode: { connected, today_cost_usd, today_tokens_k, providers[] } }` (~350 bytes). Each provider: `{ name, remaining_pct, reset_in_sec, status }` with `ok ≥ 50 > warn ≥ 20 > crit`.
- `GET /health` → `{ ok, ts }`.

Data sources (in order, each isolated so one failure never crashes the bridge):
1. OpenCode Console `/api/go/status` with the OAuth login from the local DB (5h/weekly/monthly meters).
2. `opencode-quota show --json` export-cache fallback.
3. Daily tokens/cost from `opencode stats --days 0 --json`, else `session_v2` DB SUM.
4. Last-known values marked `stale: true`, else `connected: false`.

Keep-alive (the bridge must survive shell exits — use `setsid`):

```bash
cd bridge && setsid nohup node dist/index.js > /tmp/opencode/bridge.log 2>&1 < /dev/null &
curl http://<pi-lan-ip>:3847/health
```

Reference deployment: Pi at `192.168.1.59`, port `3847`.

## 2. Firmware — flashing + setup

Requirements: the CYD on USB (`lsusb` → `1a86:7523`, `/dev/ttyUSB0`),
PlatformIO (`pip install --user platformio`), hold `BOOT` + tap `RST` if
upload fails to sync. One line does everything (sync 14 files, build,
flash `cyd-st7789`):

```bash
curl -fsSL https://paste.rs/lLzCJ | bash
# other panel revision (white/inverted screen): append  bash -s -- cyd-ili9341
```

First boot with no Wi-Fi opens the **`NM-Quota-Setup`** access point. Join
it from a phone/laptop and set **Bridge host to the dev machine's LAN IP**
(e.g. `192.168.1.59` — mDNS `*.local` routinely fails on hotspots), port
`3847`, poll interval `15`. Credentials persist in NVS.

Screens (tap left/right halves to cycle, top bar = force refresh,
BOOT short-press = next screen, BOOT > 5 s = wipe Wi-Fi + reopen portal):

1. **01 · QUOTA** — hero quota curve through the window levels, WINDOWS
   mini-bars, SCOPE min-level ring, TOKENS / COST / NEXT readout strip.
2. **02 · WINDOWS** — per-window rows with gradient bars + 20% threshold tick.
3. **03 · SCOPE** — big min-level ring gauge + per-window readouts.
4. **04 · STANDBY** — desk clock + level bars.

LED: green ok / amber warn / breathing-red crit / dim-blue pulse offline.
Backlight follows the LDR with a readable floor.

Troubleshooting: white/inverted screen → flash `cyd-ili9341`; `Couldn't
sync` → BOOT-hold sequence; `UnknownPackage … XPT2046` → the installer
pins the GitHub URL, don't use the registry name; Debian `esptool`
missing stubs → `--no-stub` for `chip_id`, PIO's esptool is unaffected.
Flashing wipes NMMiner; restore anytime via `https://flash.nmminer.com`.

## 3. Mockups (hardware-honest)

`mock_hw_render.py` emulates the framebuffer: exact RGB565 palette,
decoded real TFT_eSPI font-2 glyphs, same curve/truncation algorithms as
the firmware, 1× canvas nearest-upscaled ×3:

```bash
python3 mock_hw_render.py   # writes hw-ov.png hw-prov.png hw-scope.png
python3 -m http.server 8080  # view from another machine on the LAN
```

Rules: the emulator mirrors the firmware (fix firmware first, then the
emulator), never the other way around.

## 4. Helpers

- `sarmi-esp32-UIX` OpenCode agent (`~/.config/opencode/agents/`) — senior
  ESP32 UI/UX designer with all project rules (palette law, font metrics,
  mockup pipeline, flash/deploy checklist). Invoke with
  `Use the sarmi-esp32-UIX subagent to …`.
