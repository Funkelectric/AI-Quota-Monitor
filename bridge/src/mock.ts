/**
 * Mock data generator for UI testing without live OpenCode.
 * Simulates dynamic quota drain, reset countdowns, and ok/warn/crit transitions.
 */
import {
  overallStatusFor,
  statusForPct,
  type QuotaPayload,
  type QuotaPool,
} from "./types.js";

interface MockPoolState extends QuotaPool {
  drainPerMin: number;
  windowSec: number;
}

const ocProviders: MockPoolState[] = [
  { name: "Go 5h", remaining_pct: 82, reset_in_sec: 4 * 3600, status: "ok", drainPerMin: 0.4, windowSec: 5 * 3600 },
  { name: "Go Week", remaining_pct: 64, reset_in_sec: 2 * 86400, status: "ok", drainPerMin: 0.05, windowSec: 7 * 86400 },
  { name: "Go Month", remaining_pct: 34, reset_in_sec: 12 * 86400, status: "warn", drainPerMin: 0.02, windowSec: 30 * 86400 },
];

let cost = 1.42;
let tokensK = 485;

function tickPool(p: MockPoolState, elapsedSec: number): void {
  p.reset_in_sec -= elapsedSec;
  if (p.reset_in_sec <= 0) {
    // Window reset: refill + re-arm
    p.remaining_pct = 90 + Math.random() * 10;
    p.reset_in_sec = p.windowSec;
  } else {
    p.remaining_pct = Math.max(0, p.remaining_pct - p.drainPerMin * (elapsedSec / 60));
  }
  p.status = statusForPct(p.remaining_pct);
}

function snapshotPools(pools: MockPoolState[]): QuotaPool[] {
  return pools.map(({ name, remaining_pct, reset_in_sec, status }) => ({
    name,
    remaining_pct: Math.round(remaining_pct * 10) / 10,
    reset_in_sec: Math.max(0, Math.round(reset_in_sec)),
    status,
  }));
}

let lastTick = Date.now();

/** Advance the simulation clock and return the current payload. */
export function mockQuotaPayload(): QuotaPayload {
  const now = Date.now();
  const elapsedSec = Math.min(3600, Math.max(0, (now - lastTick) / 1000));
  lastTick = now;

  for (const p of ocProviders) tickPool(p, elapsedSec);

  // Simulate spend creeping up during the day
  cost = Math.round((cost + elapsedSec * 0.0002) * 100) / 100;
  tokensK = Math.round(tokensK + elapsedSec * 0.05);

  const payload: QuotaPayload = {
    ts: Math.floor(now / 1000),
    overall_status: "ok",
    opencode: {
      connected: true,
      today_cost_usd: cost,
      today_tokens_k: tokensK,
      providers: snapshotPools(ocProviders),
    },
  };
  payload.overall_status = overallStatusFor(payload);
  return payload;
}

/** Reset mock state (useful for tests). */
export function resetMockState(): void {
  ocProviders[0].remaining_pct = 82;
  ocProviders[0].reset_in_sec = 4 * 3600;
  ocProviders[1].remaining_pct = 64;
  ocProviders[1].reset_in_sec = 2 * 86400;
  ocProviders[2].remaining_pct = 34;
  ocProviders[2].reset_in_sec = 12 * 86400;
  cost = 1.42;
  tokensK = 485;
  lastTick = Date.now();
}
