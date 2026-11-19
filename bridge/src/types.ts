/**
 * Unified QuotaPayload interfaces (OpenCode only).
 * Keep the payload compact (< 2 KB) so ArduinoJson parses reliably.
 */

export type HealthStatus = "ok" | "warn" | "crit";
export type OverallStatus = "ok" | "warn" | "crit" | "offline";

export interface QuotaPool {
  /** Display name, e.g. "Go 5h", "Go Week" */
  name: string;
  /** 0-100 remaining quota */
  remaining_pct: number;
  /** Seconds until reset */
  reset_in_sec: number;
  status: HealthStatus;
}

export interface OpenCodeBlock {
  connected: boolean;
  today_cost_usd: number;
  /** Tokens used today, in thousands */
  today_tokens_k: number;
  providers: QuotaPool[];
  /** True when values are last-known (CLI/API unreachable) */
  stale?: boolean;
}

export interface QuotaPayload {
  /** Unix epoch seconds */
  ts: number;
  overall_status: OverallStatus;
  opencode: OpenCodeBlock;
}

/** Thresholds */
export function statusForPct(remaining_pct: number): HealthStatus {
  if (remaining_pct < 20) return "crit";
  if (remaining_pct < 50) return "warn";
  return "ok";
}

export function overallStatusFor(payload: Pick<QuotaPayload, "opencode">): OverallStatus {
  const { opencode } = payload;
  if (!opencode.connected) return "offline";
  const statuses: HealthStatus[] = opencode.providers.map((p) => p.status);
  if (statuses.includes("crit")) return "crit";
  if (statuses.includes("warn")) return "warn";
  return "ok";
}
