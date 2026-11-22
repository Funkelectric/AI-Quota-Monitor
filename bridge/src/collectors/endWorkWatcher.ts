/**
 * Auto-fire END OF WORK / END OF TASK when a user-facing OpenCode
 * conversation goes idle.
 *
 * Watches the OpenCode SQLite DB (`session_v2`): a root session
 * (`parent_id IS NULL`, so background subagents don't spam) whose `time_idle`
 * advances past `time_busy` has just "given back control to the user".
 * On each new idle transition we latch an event with the conversation title
 * + pretty model + busy-children count, which the device picks up on its
 * next quota poll (<15s) via the embedded `endofwork` block:
 *   running == 0 -> END OF WORK (fully done)
 *   running > 0  -> END OF TASK (agents still running in background)
 *
 * First run only seeds the baseline (no flood for old sessions); later runs
 * fire only for transitions newer than RECENT_MS so a long bridge outage
 * never replays stale endings. A per-tick recount keeps the latched slot's
 * count fresh; a recount-to-zero re-fires as END OF WORK (new id).
 */
import { DatabaseSync } from "node:sqlite";
import { existsSync } from "node:fs";
import { getOpencodeDbPath } from "./opencode.js";
import { getPending, postEndWork, setRunningAgents } from "../endWorkStore.js";

const RECENT_MS = 15 * 60 * 1000;
const MAX_TITLE = 23;

const lastIdle = new Map<string, number>();
let seeded = false;

function prettyModel(raw: string | null): string {
  try {
    const m = JSON.parse(raw ?? "") as { id?: string };
    const id = (m.id ?? "").trim() || "?";
    return id
      .split("-")
      .map((w) => (/^[a-z]+$/i.test(w) ? w.charAt(0).toUpperCase() + w.slice(1) : w))
      .join(" ")
      .slice(0, 31);
  } catch {
    return String(raw ?? "?").slice(0, 31);
  }
}

interface IdleRow {
  id: string;
  title: string | null;
  model: string | null;
  agent: string | null;
  time_busy: number | null;
  time_idle: number | null;
}

/** Still-running work for a root session: busy subagents + running shell jobs.
 * Subagents are `session_v2` children with no idle stamp yet (recency-guarded
 * against crashed agents). Shells are `job` rows with `status='running'`
 * (e.g. a background `python3 -m http.server`) — no recency guard: a server
 * running for hours is legitimately still running. */
function countRunning(db: InstanceType<typeof DatabaseSync>, rootId: string, now: number): number {
  let n = 0;
  try {
    const row = db
      .prepare(
        "SELECT COUNT(*) AS n FROM session_v2 WHERE parent_id = ? AND (time_idle IS NULL OR time_busy >= time_idle) AND time_updated > ?",
      )
      .get(rootId, now - RECENT_MS) as unknown as { n: number | null };
    n += Math.floor(Number(row?.n) || 0);
  } catch {
    // ignore
  }
  try {
    const job = db
      .prepare(
        "SELECT COUNT(*) AS n FROM job WHERE status = 'running' AND (session_id = ? OR session_id IN (SELECT id FROM session_v2 WHERE parent_id = ?))",
      )
      .get(rootId, rootId) as unknown as { n: number | null };
    n += Math.floor(Number(job?.n) || 0);
  } catch {
    // ignore (older DBs may lack the job table)
  }
  return Math.max(0, Math.min(99, n));
}

/** Poll once. Returns the fired event, if any. */
export function pollEndWorkWatcher(dbPath: string = getOpencodeDbPath()): { fired: boolean; id?: string } {
  if (process.env.ENDWORK_WATCH === "0") return { fired: false };
  try {
    if (!existsSync(dbPath)) return { fired: false };
    const db = new DatabaseSync(dbPath, { readOnly: true });
    try {
      const rows = db
        .prepare(
          "SELECT id, title, model, agent, time_busy, time_idle FROM session_v2 WHERE parent_id IS NULL AND time_idle IS NOT NULL ORDER BY time_idle DESC LIMIT 10",
        )
        .all() as unknown as IdleRow[];
      const now = Date.now();
      if (!seeded) {
        for (const r of rows) {
          if (r.time_idle) lastIdle.set(r.id, r.time_idle);
        }
        seeded = true;
        return { fired: false };
      }
      for (const r of rows) {
        if (!r.time_idle || !r.id) continue;
        const prev = lastIdle.get(r.id) ?? 0;
        lastIdle.set(r.id, r.time_idle);
        // New idle transition, from a real work cycle, and recent.
        if (r.time_idle > prev && (r.time_busy ?? 0) < r.time_idle && now - r.time_idle < RECENT_MS) {
          const title = String(r.title ?? "").slice(0, MAX_TITLE) || "work";
          if (title === "untitled") continue;
          const running = countRunning(db, r.id, now);
          const entry = postEndWork({
            title,
            model: prettyModel(r.model),
            session: String(r.agent ?? "").slice(0, MAX_TITLE),
            running,
            root_id: r.id,
          });
          console.log(`[endwork] auto-fired for "${title}" (${entry.id}) running=${running}`);
          return { fired: true, id: entry.id };
        }
      }
      // No new transition: keep the latched slot's running count fresh so
      // END OF TASK flips to END OF WORK when the last child/job finishes.
      const pend = getPending();
      if (pend) {
        const rootId =
          pend.root_id ||
          rows.find((r) => r.title && String(r.title).slice(0, MAX_TITLE) === pend.title)?.id;
        if (rootId) {
          const n = countRunning(db, rootId, now);
          if (n !== pend.running_agents) {
            if (n === 0 && pend.running_agents > 0) {
              // Last agent finished: re-fire as END OF WORK (new id re-latches
              // even if the user already dismissed TASK).
              const entry = postEndWork({
                title: pend.title,
                model: pend.model,
                session: pend.session,
                running: 0,
                root_id: rootId,
              });
              console.log(`[endwork] TASK -> WORK for "${pend.title}" (${entry.id})`);
              return { fired: true, id: entry.id };
            }
            setRunningAgents(n);
          }
        }
      }
      return { fired: false };
    } finally {
      db.close();
    }
  } catch (err) {
    console.warn(`[endwork] watch failed: ${String(err).slice(0, 160)}`);
    return { fired: false };
  }
}

/** Test hook: drop the baseline so the next poll seeds again. */
export function resetEndWorkWatcher(): void {
  lastIdle.clear();
  seeded = false;
}
