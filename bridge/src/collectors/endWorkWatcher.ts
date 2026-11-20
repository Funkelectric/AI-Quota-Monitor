/**
 * Auto-fire END OF WORK when a user-facing OpenCode conversation goes idle.
 *
 * Watches the OpenCode SQLite DB (`session_v2`): a root session
 * (`parent_id IS NULL`, so background subagents don't spam) whose `time_idle`
 * advances past `time_busy` has just "given back control to the user".
 * On each new idle transition we latch an end-of-work event with the
 * conversation title + pretty model, which the CYD picks up on its next
 * quota poll (<15s) via the embedded `endofwork` block.
 *
 * First run only seeds the baseline (no flood for old sessions); later runs
 * fire only for transitions newer than RECENT_MS so a long bridge outage
 * never replays stale endings.
 */
import { DatabaseSync } from "node:sqlite";
import { existsSync } from "node:fs";
import { getOpencodeDbPath } from "./opencode.js";
import { postEndWork } from "../endWorkStore.js";

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
          const entry = postEndWork({
            title,
            model: prettyModel(r.model),
            session: String(r.agent ?? "").slice(0, MAX_TITLE),
          });
          console.log(`[endwork] auto-fired for "${title}" (${entry.id})`);
          return { fired: true, id: entry.id };
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
