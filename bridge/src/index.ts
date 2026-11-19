/** Entry point: HTTP server + mDNS + optional Serial. */
import "dotenv/config";
import { Bonjour } from "bonjour-service";
import { collectOpenCode } from "./collectors/opencode.js";
import { mockQuotaPayload } from "./mock.js";
import { startHttpServer } from "./transports/http.js";
import { startSerialPusher } from "./transports/serial.js";
import { overallStatusFor, type QuotaPayload } from "./types.js";

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

async function livePayload(): Promise<QuotaPayload> {
  const opencode = await collectOpenCode();
  const payload: QuotaPayload = {
    ts: Math.floor(Date.now() / 1000),
    overall_status: "ok",
    opencode,
  };
  payload.overall_status = overallStatusFor(payload);
  return payload;
}

function getPayload(): QuotaPayload | Promise<QuotaPayload> {
  if (useMock) return mockQuotaPayload();
  return livePayload();
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
