# PLAN: CYD Touch-Answer for OpenCode Questions (05 · ASK)

> Status: feasible — YES, with one bridge-side plugin (OpenCode core does not expose pending `question` tool calls over HTTP today).
> Target: when OpenCode asks `1/2/3 choice`, the CYD pops a new `05 · ASK` screen with large bottom buttons — tap answers, no typing `enter your choice`.

## 1. Feasibility verdict

Yes. Resistive touch + existing Wi-Fi poll loop already supports it. What is missing today:

* `bridge/src/transports/http.ts` only serves `GET /api/quota` + `GET /health`. No question queue.
* `firmware/src/main.cpp` touch routing is `top bar = refresh / left half = prev / right half = next`. No hitboxes.
* OpenCode has no built-in "pending question" HTTP endpoint, so the bridge cannot snoop native TUI `question` picker calls. We must **source questions explicitly** via a tiny OpenCode plugin / MCP tool (recommended: `cyd_ask`).

Workaround NOT recommended: scraping TUI stdout for `1/2/3` prompts — fragile, breaks on versions, no clean answer injection.

Recommended path: custom tool `cyd_ask(question, options[])` that the agent prefers when `CYD_BRIDGE_URL` is reachable, with graceful fallback to native `question` on timeout/offline.

## 2. UX proposal (for `sarmi-esp32-UIX` mockup `hw-ask.png`)

Reuse exact style from `firmware/src/ui/screens.cpp` + `firmware/include/ui_theme.h` + `mock_hw_render.py`:

* Palette law (RGB565, no new colors): `BG 0x1082 / CARD 0x10C4 / TEXT 0xFFFF / DIM 0x8CB3 / GREEN 0x3DCA / AMBER 0xD4C4 / RED 0xFA89 / BLUE 0x2D9D / ICE 0x7EBF / EDGE 0x2988 / GRID 0x1906`.
* Fonts: `font2` (16px) for question + button labels, `font1` for `TINY` micro-labels, `font4` only for big `%` elsewhere (not needed here). Header `28px`, `spaced()` tracking `2`.
* Layout 320×240 landscape (`DISPLAY_ROTATION 3`, see `firmware/include/config.h`):
  * Header `0..28`: left `05 · ASK` (`spaced`, DIM on CARD), right cluster `LIVE/WIFI/clock` + ICE dot, `EDGE` hairline at `y=28`. Same `header()` as `drawOverview/drawProviders`.
  * Question card `8,34,311,162` (`w=304,h=129`, rounded r=4 EDGE / inner r=3 BG): `tiny("OPENCODE ASKS")` DIM at `(13,38)`, Q `font-2` TEXT at `(13,50)`, sub `font-2` DIM at `(13,68)`, `EDGE` hairline `y=88 x13..307`. Truncate to `292px` via `textWidth()` (hero-label loop).
  * Button bar 3-up `ASK_BTNS_3=(8,172,97,48),(111,172,97,48),(214,172,98,48)` 6px gaps, rounded r=3 EDGE (focused: ICE), `CARD` fill, centered `font-2` label `y+(h-16)/2`. Focused: ICE outline+text; answered: GREEN flash 300ms (firmware). Hint `tiny("TAP TO ANSWER · BOOT = NEXT")` centered `y=226`.
  * Variants: 2 opts → `ASK_BTNS_2=(8,172,149,48),(163,172,149,48)`; 4 opts → 2×2 `ASK_BTNS_4=(8,124,149,44),(163,124,149,44),(8,174,149,44),(163,174,149,44)` + card shrinks to `y34..116` (no preview rows); >4 → first 3 + fallback to TUI.
* Touch: resistive XPT2046 via `touchTap()` in `firmware/src/ui/display.cpp`. Targets `≥44px` tall per Apple/CYD resistive rule. Debounce existing `600ms hold = not a tap` stays.
* Alert: `LED` breathe blue (`ledTick(ST_OFFLINE)` pattern in `firmware/src/led_controller.cpp`) + auto-popup overrides current screen, any tap outside buttons = stay (no accidental screen change while pending).

Exact hitboxes (final, from `hw-ask.png`):

```
3 opts: (8,172,97,48), (111,172,97,48), (214,172,98,48)  // 6px gaps
2 opts: (8,172,149,48), (163,172,149,48)
4 opts: (8,124,149,44), (163,124,149,44), (8,174,149,44), (163,174,149,44)
Rows: x=13, y=94/112/130 pitch 18, truncate 292px
```

## 3. System architecture delta

```text
[OpenCode Agent] --cyd_ask Q--> [Bridge :3847] --GET /api/ask--> [CYD polls 5s]
     ^                               |  POST /api/ask/answer <--tap--+
     +---blocks poll (30s timeout)---+                                |
         fallback to native question on timeout/offline              |
```

No change to quota path (`GET /api/quota` stays `<2KB`, `ArduinoJson`, `QUOTA_JSON_MAX 2048` in `config.h`).

### 3.1 Bridge API (extends `bridge/src/transports/http.ts`)

```jsonc
// GET /api/ask → 200 (pending) or 204 (none)
{
  "id": "q_9f3a",
  "ts": 1795050000,
  "session": "curious-meadow",
  "question": "Which model for refactor?",
  "detail": "opencode asks · 2m ago",   // subtitle, ≤48 chars
  "options": [
    { "id": "quick", "label": "1 · Quick patch", "hint": "fast" },
    { "id": "full",  "label": "2 · Full rewrite", "hint": "" },
    { "id": "skip",  "label": "3 · Skip", "hint": "" }
  ],
  "timeout_sec": 90,
  "answered": false
}
// POST /api/ask/answer { "id": "q_9f3a", "option_id": "full" } → { "ok": true }
// POST /api/ask { question, options[] } ← called by plugin/MCP tool (LAN only)
```

Rules:

* Single pending slot (`Map<id, entry>` + `currentId`). New `POST` replaces stale (old waiter gets `replaced`).
* `timeout_sec` default `90`, max `300`. Waiter long-polls (plugin `await`s with `AbortController`); CYD polls `GET /api/ask` every `5s` (separate from quota `15s`).
* Payload `<1KB`: truncate `question ≤120 chars`, `label ≤24 chars`, `options ≤4` (bridge trims + sets `truncated:true`).
* `GET /health` gains `{ "ask_pending": true|false }` for debugging, no break.
* Serial: newline JSON `{"type":"ask",…}` / `{"type":"answer",…}` on same `115200` link (`bridge/src/transports/serial.ts`), CYD `serialPump()` in `main.cpp` routes by `type`.

### 3.2 Question source — OpenCode plugin (required)

Native `question` tool cannot be hijacked remotely. Provide `bridge/opencode-plugin/cyd-ask.ts` (Bun/JS OpenCode plugin):

```ts
// pseudo: registers tool `cyd_ask`
export const tool = {
  id: "cyd_ask",
  description: "Ask user via CYD hardware buttons (preferred when reachable)",
  args: { question: "string", options: "string[]" },
  async run({ question, options }) {
    const bridge = process.env.CYD_BRIDGE_URL ?? "http://192.168.1.59:3847";
    try {
      const q = await POST(`${bridge}/api/ask`, { question, options, timeout_sec: 90 }, { timeout: 3_000 });
      const ans = await pollAnswer(q.id, 90_000); // GET /api/ask?id=… until answered
      return ans ?? fallbackToNativeQuestion();
    } catch { return fallbackToNativeQuestion(); }
  }
};
```

* Agent instruction (in plugin `system.md` or repo `AGENTS.md`): "If `cyd_ask` succeeds (bridge reachable), USE IT instead of native `question` for ≤4-option picks."
* Alt without plugin: MCP server `cyd` exposing same tool (`npx tsx bridge/src/mcp.ts`). Plugin preferred — zero TUI config.
* Security: `POST /api/ask` binds `0.0.0.0` but answers only affect local session; add `CYD_TOKEN` env opt (compare `Authorization: Bearer`) — document, default open on LAN like quota today.

## 4. Firmware changes (both `cyd-st7789` + `cyd-ili9341`)

Touched files: `firmware/src/ui/screens.{h,cpp}`, `firmware/src/main.cpp`, `firmware/src/network.{h,cpp}`, `firmware/src/quota_state.{h,cpp}` (or new `ask_state.h`), `firmware/include/config.h`.

1. `config.h`: add `#define SCR_ASK 4`, bump `SCR_COUNT 5`; `#define ASK_JSON_MAX 1024`, `#define ASK_OPTS_MAX 4`, `#define ASK_OPT_LABEL_MAX 24`, `#define ASK_POLL_SEC 5`.
2. New `ask_state.h/.cpp` (mirror `quota_state`): `struct AskState { char id[16]; char question[121]; char options[4][25]; uint8_t count; unsigned long expires_ms; bool pending; bool fresh; }`, `parseAskPayload()` with static `JsonDocument` (heap-stable, no `String` loops).
3. `network.cpp`: `netFetchAsk(cfg, out)` → `GET /api/ask`, `netPostAnswer(cfg, id, option_id)` → `POST /api/ask/answer` (reuse `HTTPClient`, `HTTP_TIMEOUT_MS 8000`).
4. `screens.cpp`: `drawAsk(ask, netUp, serialMode)` per §2. Reuse `header()`, `spaced()`, `tiny()`, `statusColor()` only. No new colors/fonts. Truncate via `textWidth()` like hero labels.
5. `main.cpp`: `g_ask` + `g_lastAskPoll`; in `loop()`: poll ask every `5s`; on new `id` → `g_screen=SCR_ASK; render(); ledAlert`. Touch routing: if `g_screen==SCR_ASK && ask.pending && ty>=166` → hit-test buttons → `netPostAnswer()` + optimistic green flash + `render()`; else existing `top bar / L/R` nav (but disable L/R while pending to avoid losing question; `BOOT` short-press = next screen only when no pending, long-press `>5s` unchanged).
6. `serialPump()`: peek `{"type":"ask"` vs quota payload; route accordingly (USB desk setup keeps working).

Memory: ask doc `~1KB` static, no extra `DynamicJsonDocument` per poll (same soak rule as §5 in `PLAN.md`).

## 5. Bridge changes checklist

* `bridge/src/types.ts`: add `AskOption`, `AskPending`, `AskAnswer` + `truncateAsk()` helper.
* `bridge/src/askStore.ts` (new): in-memory slot, `postAsk()`, `getPending()`, `answerAsk()`, expiry sweeper (`setInterval 5s`).
* `bridge/src/transports/http.ts`: `GET /api/ask`, `POST /api/ask`, `POST /api/ask/answer` + CORS + `Content-Length` guard `≤2048`.
* `bridge/src/transports/serial.ts`: also push `ask` frames interleaved with quota (alternate frames, or `{"type":…}` envelope).
* `bridge/src/mock.ts`: `mockAskPayload()` cycling 2/3/4-option samples for UI testing (`--mock` serves rotating question every 30s).
* `bridge/opencode-plugin/cyd-ask.ts` (new) + README section + `.env.example` additions (`CYD_BRIDGE_URL`, `ASK_TIMEOUT_SEC`, `CYD_TOKEN`).

## 6. Phased tasks

* [ ] P0 Mockup: `sarmi-esp32-UIX` lands `hw-ask.png` + geometry (this issue). Verify 1× canvas → ×3 nearest, RGB565 only.
* [ ] P1 Bridge API + store + mock (`GET/POST /api/ask`, expiry, `curl` verify, `npm run dev -- --mock` shows rotating question).
* [ ] P2 Plugin/MCP `cyd_ask` with timeout fallback; `AGENTS.md` nudge; manual `POST /api/ask` → TUI returns answer.
* [ ] P3 Firmware `ask_state` + `drawAsk` + `netFetchAsk/PostAnswer` + touch hitboxes; `pio run -e cyd-st7789 -e cyd-ili9341` zero errors.
* [ ] P4 Integration: Wi-Fi poll + Serial frames, auto-popup, LED breathe-blue, stale/timeout (`TIMEOUT` label, auto-back to quota), offline (`WAITING` keeps quota screens).
* [ ] P5 Polish: README flash/test section, `python3 mock_hw_render.py` parity check (emulator mirrors firmware), soak 1h heap check via `ESP.getFreeHeap()`.

## 7. Verification

```bash
# bridge
cd bridge && npm run dev -- --mock &
curl -s http://localhost:3847/api/ask | jq .
curl -s -X POST http://localhost:3847/api/ask/answer -H 'Content-Type: application/json' -d '{"id":"q_9f3a","option_id":"full"}'

# firmware
pio run -e cyd-st7789 && pio run -e cyd-ili9341
python3 mock_hw_render.py && xdg-open hw-ask.png  # 960×720, compare vs device photo
```

Pass = tap on CYD answers pending `cyd_ask` within 5s poll, TUI resumes without typing; timeout falls back to native question; no quota regression (`/api/quota` still `<2KB`).

## 8. Open questions / risks

1. Touch accuracy at screen edges (resistive drift) → keep `MARGIN 8` + `≥44px` targets; calibrate `TOUCH_RAW_*` if miss rate >5%.
2. Long questions (>120 chars) → bridge truncates; agent should keep `question ≤80 chars` + put context in `detail`.
3. Multi-agent concurrent asks → single-slot + `replaced` is intentional v1; queue later if needed.
4. mDNS `*.local` flaky on hotspots (known, see `README.md`) → plugin uses LAN IP (`192.168.1.59`) by default, same as Wi-Fi portal note.
