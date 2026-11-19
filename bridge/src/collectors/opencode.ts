/**
 * OpenCode quota collector (Phase 2).
 *
 * Source priority:
 *  1. OpenCode Console API directly (`/api/go/status`) using the OAuth login
 *     stored in the OpenCode SQLite DB (`credential` table, integration `opencode`).
 *     Same endpoint the `@slkiser/opencode-quota` plugin uses; works with a
 *     plain `fetch` + browser-like User-Agent (Cloudflare blocks bare clients).
 *  2. `npx @slkiser/opencode-quota show --json` export-cache fallback.
 *  3. Daily tokens/cost from `opencode stats --days 0 --json`, with a
 *     `session_v2` DB SUM fallback so usage still works when the CLI is busy.
 *
 * Error isolation: every source is wrapped in try/catch with a short timeout.
 * A failing source never throws — the collector returns the last-known payload
 * with `stale: true`, or `connected: false` when nothing ever succeeded.
 * Results are cached for POLL_OC_SEC (default 45s).
 */
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { DatabaseSync } from "node:sqlite";
import { statusForPct, type OpenCodeBlock, type QuotaPool } from "../types.js";

const execFileAsync = promisify(execFile);

const UA = "opencode-quota-bridge/0.1.0 (Node)";
const GO_STATUS_PATH = "/api/go/status";
const DEFAULT_SERVER = "https://opencode.ai/console";

interface ConsoleCredential {
  accessToken: string;
  server: string;
  orgId?: string;
  email?: string;
}

interface GoWindow {
  percentRemaining: number;
  reset_in_sec: number;
}

interface GoStatus {
  rolling: GoWindow;
  weekly: GoWindow;
  monthly: GoWindow;
}

let cache: { at: number; data: OpenCodeBlock } | null = null;

function cacheTtlMs(): number {
  const sec = Number(process.env.POLL_OC_SEC ?? "45");
  return (Number.isFinite(sec) && sec > 0 ? sec : 45) * 1000;
}

export function getOpencodeDbPath(): string {
  const override = process.env.OPENCODE_DB?.trim();
  if (override) return override;
  const dataDir =
    process.env.XDG_DATA_HOME?.trim() || join(homedir(), ".local", "share", "opencode");
  return join(dataDir, "opencode.db");
}

/** Read the active `opencode` OAuth login from the OpenCode SQLite DB. */
export function readConsoleCredential(dbPath: string = getOpencodeDbPath()): ConsoleCredential | null {
  try {
    if (!existsSync(dbPath)) return null;
    const db = new DatabaseSync(dbPath, { readOnly: true });
    try {
      const row = db
        .prepare(
          "SELECT value FROM credential WHERE integration_id = 'opencode' ORDER BY active DESC LIMIT 1",
        )
        .get() as { value: string } | undefined;
      if (!row?.value) return null;
      const v = JSON.parse(row.value) as {
        type?: string;
        access?: string;
        expires?: number;
        metadata?: { server?: string; orgID?: string; email?: string };
      };
      if (typeof v.access !== "string" || !v.access) return null;
      return {
        accessToken: v.access,
        server: v.metadata?.server || DEFAULT_SERVER,
        orgId: v.metadata?.orgID,
        email: v.metadata?.email,
      };
    } finally {
      db.close();
    }
  } catch {
    return null;
  }
}

function toWindow(label: string, meter: unknown, fallbackResetsAt?: string): GoWindow {
  const m = meter as Record<string, unknown> | null;
  const limit = Number(m?.["limitMicroCents"]);
  const used = Number(m?.["usedMicroCents"]);
  if (!m || !Number.isFinite(limit) || !Number.isFinite(used) || limit < 0 || used < 0) {
    throw new Error(`invalid ${label} meter`);
  }
  const usedPctExact = limit === 0 ? (used > 0 ? 100 : 0) : Math.min(100, Math.max(0, (used / limit) * 100));
  const percentRemaining = Math.round((100 - usedPctExact) * 10) / 10;
  const resetsAt =
    typeof m["resetsAt"] === "string" && m["resetsAt"] ? (m["resetsAt"] as string) : fallbackResetsAt;
  const resetMs = resetsAt ? Date.parse(resetsAt) : NaN;
  if (!Number.isFinite(resetMs)) throw new Error(`invalid ${label} resetsAt`);
  return {
    percentRemaining,
    reset_in_sec: Math.max(0, Math.round((resetMs - Date.now()) / 1000)),
  };
}

function toPool(name: string, w: GoWindow): QuotaPool {
  return {
    name,
    remaining_pct: w.percentRemaining,
    reset_in_sec: w.reset_in_sec,
    status: statusForPct(w.percentRemaining),
  };
}

/** Query the Console Go subscription meters (5h / weekly / monthly). */
export async function queryGoStatus(
  cred: ConsoleCredential,
  timeoutMs = 5_000,
): Promise<GoStatus> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(`${cred.server}${GO_STATUS_PATH}`, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${cred.accessToken}`,
        Accept: "application/json",
        "User-Agent": UA,
        ...(cred.orgId ? { "x-org-id": cred.orgId } : {}),
      },
      signal: ctrl.signal,
    });
    if (!res.ok) throw new Error(`console ${GO_STATUS_PATH} -> HTTP ${res.status}`);
    const json = (await res.json()) as {
      access?: { endsAt?: string; meters?: Record<string, unknown> };
    };
    const meters = json?.access?.meters;
    if (!meters) throw new Error("console response has no access.meters (no Go subscription?)");
    const endsAt = json.access?.endsAt;
    return {
      rolling: toWindow("fiveHour", meters["fiveHour"], endsAt),
      weekly: toWindow("week", meters["week"], endsAt),
      monthly: toWindow("month", meters["month"], endsAt),
    };
  } finally {
    clearTimeout(t);
  }
}

/** Daily usage via `opencode stats --days 0 --json`, fallback to DB SUM. */
export async function getTodayUsage(
  dbPath: string = getOpencodeDbPath(),
): Promise<{ cost: number; tokens_k: number }> {
  try {
    // AUDIT C2: 15s -> 5s so a hung CLI can't blow the 8s firmware budget.
    const { stdout } = await execFileAsync("opencode", ["stats", "--days", "0", "--json"], {
      timeout: 5_000,
      maxBuffer: 4 * 1024 * 1024,
    });
    const stats = JSON.parse(stdout) as {
      cost?: number;
      tokens?: { input?: number; output?: number; reasoning?: number; cache?: { read?: number; write?: number } };
    };
    const t = stats.tokens ?? {};
    const total =
      (t.input ?? 0) + (t.output ?? 0) + (t.reasoning ?? 0) + (t.cache?.read ?? 0) + (t.cache?.write ?? 0);
    return {
      cost: Math.round((stats.cost ?? 0) * 100) / 100,
      tokens_k: Math.round(total / 100) / 10,
    };
  } catch {
    // Fallback: sum today's sessions straight from the DB.
    try {
      if (!existsSync(dbPath)) return { cost: 0, tokens_k: 0 };
      const db = new DatabaseSync(dbPath, { readOnly: true });
      try {
        const now = new Date();
        now.setHours(0, 0, 0, 0);
        const row = db
          .prepare(
            "SELECT SUM(cost) AS c, SUM(tokens_input+tokens_output+tokens_reasoning+tokens_cache_read+tokens_cache_write) AS t FROM session_v2 WHERE time_created >= ?",
          )
          .get(now.getTime()) as { c: number | null; t: number | null };
        const total = row?.t ?? 0;
        return {
          cost: Math.round((row?.c ?? 0) * 100) / 100,
          tokens_k: Math.round(total / 100) / 10,
        };
      } finally {
        db.close();
      }
    } catch {
      return { cost: 0, tokens_k: 0 };
    }
  }
}

interface QuotaShowJson {
  providers?: Record<
    string,
    | { status: string; entries?: Array<Record<string, unknown>>; fetchedAt?: string }
    | undefined
  >;
}

/** Fallback: parse `opencode-quota show --json` percent entries into pools. */
export async function readQuotaShowFallback(timeoutMs = 8_000): Promise<QuotaPool[]> {
  const bin = process.env.OPENCODE_QUOTA_BIN?.trim() || "npx";
  const args =
    bin === "npx"
      ? ["-y", "@slkiser/opencode-quota@latest", "show", "--json"]
      : ["show", "--json"];
  const { stdout } = await execFileAsync(bin, args, { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 });
  const doc = JSON.parse(stdout) as QuotaShowJson;
  const pools: QuotaPool[] = [];
  for (const [providerId, provider] of Object.entries(doc.providers ?? {})) {
    if (!provider || (provider.status !== "ok" && provider.status !== "partial")) continue;
    for (const e of provider.entries ?? []) {
      if (e["renderType"] !== "percent" || typeof e["percentRemaining"] !== "number") continue;
      const remaining = Math.round((e["percentRemaining"] as number) * 10) / 10;
      const resetAt = e["resetAt"];
      const reset_in_sec =
        typeof resetAt === "number"
          ? Math.max(0, Math.round(resetAt - Date.now() / 1000))
          : 0;
      pools.push({
        name: String(e["name"] ?? providerId),
        remaining_pct: remaining,
        reset_in_sec,
        status: statusForPct(remaining),
      });
      // AUDIT H2: firmware POOLS_MAX=4 (3 roomy rows, 4 condensed). Never send
      // 6 — the CYD silently drops extras and the 4th row used to overflow.
      if (pools.length >= 4) break;
    }
    if (pools.length >= 4) break;
  }
  return pools;
}

/** Recently ACTIVE sessions for the CYD 01 rotator: most-recent first.
 * "Active" = touched in the last minutes (default 10). Old sessions that
 * merely exist in the DB are not shown — otherwise the strip fills with
 * stale entries and the pager (e.g. 3/4) suggests parallel work that
 * isn't happening. */
export function getRecentSessions(dbPath: string = getOpencodeDbPath(), limit = 4): { title: string; model: string }[] {
  const activeMin = Math.max(1, Number(process.env.SESSION_ACTIVE_MIN ?? "10") || 10);
  const cutoff = Date.now() - activeMin * 60 * 1000;
  try {
    if (!existsSync(dbPath)) return [];
    const db = new DatabaseSync(dbPath, { readOnly: true });
    try {
      const rows = db
        .prepare(
          "SELECT title, model FROM session_v2 WHERE time_updated > ? ORDER BY time_updated DESC LIMIT ?",
        )
        .all(cutoff, limit) as { title: string | null; model: string | null }[];
      return rows
        .map((r) => {
          // Pretty model name only: "muse-spark-1.3-contributor" -> "Muse Spark 1.3 Contributor".
          // No provider prefix, no thinking-level variant.
          let model = "?";
          try {
            const m = JSON.parse(r.model ?? "") as { id?: string };
            const rawId = (m.id ?? "").trim() || "?";
            model = rawId
              .split("-")
              .map((w) => (/^[a-z]+$/i.test(w) ? w.charAt(0).toUpperCase() + w.slice(1) : w))
              .join(" ")
              .slice(0, 31);
          } catch {
            model = String(r.model ?? "?").slice(0, 31);
          }
          return {
            title: String(r.title ?? "untitled").slice(0, 23),
            model,
          };
        })
        // AUDIT M10: "untitled" rows are stale placeholders, not active work.
        // Drop them so the rotator never fills with 3/4 meaningless entries.
        .filter((s) => s.title && s.title !== "untitled" && s.title !== "-- idle --");
    } finally {
      db.close();
    }
  } catch {
    return [];
  }
}

let inFlight: Promise<OpenCodeBlock> | null = null;
let lastAttempt = 0;
// AUDIT H7: when serving stale, don't re-run the ≤45s chain on every poll
// (CYD every 15s + serial every 10s = retry storm). At most one background
// attempt per STALE_RETRY_MS.
const STALE_RETRY_MS = 15_000;

async function doCollect(): Promise<OpenCodeBlock> {
  const dbPath = getOpencodeDbPath();
  // Usage (local exec/DB) and Console query run concurrently so the worst
  // case is max(5s, 5s) + fallback(8s), not the sum (AUDIT C2).
  const usageP = getTodayUsage(dbPath);
  const sessions = getRecentSessions(dbPath);
  const cred = readConsoleCredential(dbPath);

  // Primary: live Console Go meters.
  try {
    if (cred) {
      const [usage, go] = await Promise.all([usageP, queryGoStatus(cred)]);
      const data: OpenCodeBlock = {
        connected: true,
        today_cost_usd: usage.cost,
        today_tokens_k: usage.tokens_k,
        providers: [
          toPool("Go 5h", go.rolling),
          toPool("Go Week", go.weekly),
          toPool("Go Month", go.monthly),
        ],
        sessions,
      };
      cache = { at: Date.now(), data };
      return data;
    }
  } catch (err) {
    console.warn(`[opencode] console query failed: ${String(err).slice(0, 160)}`);
  }

  const usage = await usageP;
  // Fallback: opencode-quota export cache.
  try {
    const pools = await readQuotaShowFallback();
    if (pools.length > 0) {
      const data: OpenCodeBlock = {
        connected: true,
        today_cost_usd: usage.cost,
        today_tokens_k: usage.tokens_k,
        providers: pools.slice(0, 4),
        sessions,
        stale: true,
      };
      cache = { at: Date.now(), data };
      return data;
    }
  } catch (err) {
    console.warn(`[opencode] quota-show fallback failed: ${String(err).slice(0, 160)}`);
  }

  // Last resort: keep serving last-known values, else report disconnected.
  if (cache) {
    const stale: OpenCodeBlock = {
      ...cache.data,
      today_cost_usd: usage.cost,
      today_tokens_k: usage.tokens_k,
      sessions: sessions.length > 0 ? sessions : cache.data.sessions,
      stale: true,
    };
    // AUDIT H7: refresh at on stale serve so TTL backoff applies; the
    // background refresher (below) picks up the next attempt.
    cache = { at: Date.now(), data: stale };
    return stale;
  }
  return {
    connected: false,
    today_cost_usd: usage.cost,
    today_tokens_k: usage.tokens_k,
    providers: [],
    sessions,
    stale: true,
  };
}

/** Synchronous read for the hot path: HTTP handler + serial pusher. */
export function getCachedBlock(): OpenCodeBlock | null {
  return cache?.data ?? null;
}

export function isCacheFresh(): boolean {
  if (!cache) return false;
  return Date.now() - cache.at < cacheTtlMs();
}

/** Trigger a background refresh (fire-and-forget, de-duplicated). */
export function refreshInBackground(): void {
  const now = Date.now();
  if (inFlight || now - lastAttempt < STALE_RETRY_MS) return;
  lastAttempt = now;
  inFlight = doCollect()
    .catch((err) => {
      console.warn(`[opencode] background refresh failed: ${String(err).slice(0, 160)}`);
      return cache?.data ?? null;
    })
    .then((d) => d as OpenCodeBlock)
    .finally(() => {
      inFlight = null;
    }) as Promise<OpenCodeBlock>;
  void inFlight;
}

export async function collectOpenCode(): Promise<OpenCodeBlock> {
  const now = Date.now();
  // Fast path: fresh cache serves in ~0ms, well under the 8s firmware budget.
  if (cache && now - cache.at < cacheTtlMs()) return cache.data;
  // Stale-while-revalidate (AUDIT C2/H7): serve last-good immediately and
  // refresh in background instead of blocking the HTTP handler ≤45s.
  if (cache) {
    refreshInBackground();
    return cache.data;
  }
  // Cold start (no cache yet): must fetch inline, but with the tightened
  // timeouts above (5s/5s/8s, usage+go concurrent).
  if (!inFlight) {
    lastAttempt = now;
    inFlight = doCollect().finally(() => {
      inFlight = null;
    });
  }
  return inFlight;
}

/** Test hook: drop the in-memory cache. */
export function resetOpenCodeCache(): void {
  cache = null;
  inFlight = null;
  lastAttempt = 0;
}
