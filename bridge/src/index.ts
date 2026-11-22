/** Entry point: HTTP server + mDNS + optional Serial. */
import "dotenv/config";
import { Bonjour } from "bonjour-service";
import { collectOpenCode, getCachedBlock, isCacheFresh, refreshInBackground } from "./collectors/opencode.js";
import { pollEndWorkWatcher } from "./collectors/endWorkWatcher.js";
import { getPending } from "./askStore.js";
import { getPending as getEndWork } from "./endWorkStore.js";
import { mockAskPayload, mockQuotaPayload } from "./mock.js";
import { startHttpServer } from "./transports/http.js";
import { startSerialPusher } from "./transports/serial.js";
import { overallStatusFor, type OpenCodeBlock, type QuotaPayload } from "./types.js";

const args = new Set(process.argv.slice(2));
const useMock = args.has("--mock");

const PORT = Number(process.env.PORT ?? "3847");
const HOST = process.env.HOST ?? "0.0.0.0";
const MDNS_NAME = process.env.MDNS_NAME ?? "quota-bridge";
const SERIAL_PORT = args.has("--serial")
  ? String(process.argv[process.argv.indexOf("--serial") + 1] ?? process.env.SERIAL_PORT ?? "")
  : (process.env.SERIAL_PORT ?? "");
const SERIAL_BAUD = Number(process.env.SERIAL_BAUD ?? "115200");
const SERIAL_INTERVAL_SEC = Number(process.env.SERIAL_INTERVAL_SEC ?? "10");

function payloadFrom(opencode: OpenCodeBlock | null): QuotaPayload | null {
  if (!opencode) return null;
  const ew = getEndWork();
  const payload: QuotaPayload = {
    ts: Math.floor(Date.now() / 1000),
    overall_status: "ok",
    opencode,
    endofwork: ew ? { id: ew.id, title: ew.title, model: ew.model, ended_at: ew.ended_at, running: ew.running_agents } : null,
  };
  payload.overall_status = overallStatusFor(payload);
  return payload;
}

async function livePayload(): Promise<QuotaPayload> {
  // Hot path (AUDIT C2): serve the background-refreshed cache synchronously
  // when fresh/stale; only the cold start awaits a collection.
  if (!isCacheFresh() && getCachedBlock()) {
    refreshInBackground();
    const fast = payloadFrom(getCachedBlock());
    if (fast) return fast;
  }
  const opencode = await collectOpenCode();
  const ew = getEndWork();
  const payload: QuotaPayload = {
    ts: Math.floor(Date.now() / 1000),
    overall_status: "ok",
    opencode,
    endofwork: ew ? { id: ew.id, title: ew.title, model: ew.model, ended_at: ew.ended_at, running: ew.running_agents } : null,
  };
  payload.overall_status = overallStatusFor(payload);
  return payload;
}

function getPayload(): QuotaPayload | Promise<QuotaPayload> {
  if (useMock) return mockQuotaPayload();
  return livePayload();
}

function getAsk() {
  if (useMock) return mockAskPayload();
  return getPending();
}

// Background refresher (AUDIT C2/H7): keep the cache warm on POLL_OC_SEC so
// HTTP handlers serve in ~0ms instead of running the ≤45s collector chain
// per request (which exceeded the 8s firmware timeout).
if (!useMock) {
  const bgSec = Math.max(10, Number(process.env.POLL_OC_SEC ?? "45") || 45);
  const warm = (): void => {
    refreshInBackground();
  };
  void collectOpenCode()
    .catch((err) => console.warn(`[bridge] warmup failed: ${String(err).slice(0, 160)}`))
    .finally(() => {
      setInterval(warm, bgSec * 1000).unref?.();
    });
  // Watch OpenCode sessions for fresh idle transitions -> auto END OF WORK.
  // Cheap local SQLite read every 5s so the CYD fires ~directly when the
  // conversation gives back control (well under its 15s quota poll).
  const watchSec = Math.max(2, Number(process.env.ENDWORK_WATCH_SEC ?? "5") || 5);
  pollEndWorkWatcher();
  setInterval(() => void pollEndWorkWatcher(), watchSec * 1000).unref?.();
}

const server = startHttpServer({ host: HOST, port: PORT, getPayload });
server.on("listening", () => {
  console.log(`[bridge] HTTP listening on http://${HOST}:${PORT} (mock=${useMock})`);
  console.log(`[bridge] GET /api/quota  GET /health`);
});

// mDNS advertisement so ESP32 can use quota-bridge.local
try {
  const bonjour = new Bonjour();
  bonjour.publish({
    name: MDNS_NAME,
    type: "http",
    port: PORT,
    txt: { path: "/api/quota" },
  });
  console.log(`[bridge] mDNS advertising ${MDNS_NAME}.local:${PORT}`);
} catch (err) {
  console.warn(`[bridge] mDNS unavailable: ${String(err)}`);
}

const serial = SERIAL_PORT
  ? startSerialPusher({
      path: SERIAL_PORT,
      baudRate: Number.isFinite(SERIAL_BAUD) ? SERIAL_BAUD : 115200,
      intervalSec: Number.isFinite(SERIAL_INTERVAL_SEC) ? SERIAL_INTERVAL_SEC : 10,
      getPayload,
      getAsk,
    })
  : null;

function shutdown(): void {
  try {
    serial?.close();
  } catch {
    // ignore
  }
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1000).unref();
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
