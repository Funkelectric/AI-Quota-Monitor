/**
 * Single-slot END OF WORK latch for the CYD END - WORK screen.
 * One pending entry at a time; a new POST replaces the old one.
 * No expiry — the entry stays until the CYD dismisses it with
 * POST /api/endofwork/dismiss (touch) or a newer entry replaces it.
 */

export interface EndWorkPending {
  id: string;
  ts: number;
  ended_at: number;
  title: string;
  model: string;
  session: string;
  /** Busy background agents: 0 = END OF WORK, >0 = END OF TASK */
  running_agents: number;
  /** Root session id the count was taken for (recount without title guessing) */
  root_id: string;
  dismissed: boolean;
  answer?: string;
}

import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Disk persistence: the latch must survive a bridge restart (service
 * update, Pi reboot), otherwise a not-yet-dismissed END OF WORK event is
 * silently lost. Single JSON file, written on every mutation.
 */
function stateFile(): string {
  const fromEnv = (process.env.ENDWORK_STATE_FILE ?? "").trim();
  if (fromEnv) return fromEnv;
  return join(homedir(), ".local", "share", "ai-quota-bridge", "endwork.json");
}

function save(): void {
  try {
    const f = stateFile();
    if (!current) {
      if (existsSync(f)) unlinkSync(f);
      return;
    }
    mkdirSync(join(f, ".."), { recursive: true });
    writeFileSync(f, JSON.stringify(current), "utf8");
  } catch {
    // persistence is best-effort; the in-memory latch still works
  }
}

function load(): void {
  try {
    const f = stateFile();
    if (!existsSync(f)) return;
    const raw = JSON.parse(readFileSync(f, "utf8")) as Partial<EndWorkPending>;
    if (!raw || typeof raw.id !== "string" || !raw.id || raw.dismissed) return;
    if (typeof raw.title !== "string") return;
    current = {
      id: raw.id.slice(0, 31),
      ts: Math.floor(Number(raw.ts) || 0),
      ended_at: Math.floor(Number(raw.ended_at) || 0),
      title: String(raw.title).slice(0, 23),
      model: String(raw.model ?? "").slice(0, 31),
      session: String(raw.session ?? "").slice(0, 23),
      running_agents: Math.max(0, Math.min(99, Math.floor(Number(raw.running_agents) || 0))),
      root_id: String(raw.root_id ?? "").slice(0, 40),
      dismissed: false,
      answer: undefined,
    };
  } catch {
    // corrupt file: start empty
  }
}

let current: EndWorkPending | null = null;

load();

const resolved = new Map<string, { entry: EndWorkPending; at: number }>();

function remember(entry: EndWorkPending): void {
  resolved.set(entry.id, { entry: { ...entry }, at: Date.now() });
  const cutoff = Date.now() - 5 * 60 * 1000;
  for (const [k, v] of resolved) {
    if (v.at < cutoff) resolved.delete(k);
  }
  while (resolved.size > 20) {
    const oldest = resolved.keys().next().value;
    if (oldest === undefined) break;
    resolved.delete(oldest);
  }
}

function eid(): string {
  const id = `e_${Date.now().toString(36)}${Math.floor(Math.random() * 0xffff).toString(36)}`;
  return id.slice(0, MAX_ID);
}

export const MAX_ID = 31;
const MAX_TITLE = 23;
const MAX_MODEL = 31;

export function postEndWork(input: {
  title?: string;
  model?: string;
  session?: string;
  running?: number;
  root_id?: string;
}): EndWorkPending {
  const title = String(input.title ?? "").slice(0, MAX_TITLE) || "work";
  const model = String(input.model ?? "").slice(0, MAX_MODEL);
  const session = String(input.session ?? "").slice(0, MAX_TITLE);
  const running = Math.max(0, Math.min(99, Math.floor(Number(input.running) || 0)));
  const now = Math.floor(Date.now() / 1000);
  const entry: EndWorkPending = {
    id: eid(),
    ts: now,
    ended_at: now,
    title,
    model,
    session,
    running_agents: running,
    root_id: String(input.root_id ?? "").slice(0, 40),
    dismissed: false,
  };
  current = entry;
  save();
  return entry;
}

/** Pending entry, or null when none / dismissed. */
export function getPending(): EndWorkPending | null {
  if (!current) return null;
  if (current.dismissed) return null;
  return current;
}

/** In-place recount for the latched slot (no re-pop, no new id). */
export function setRunningAgents(n: number): EndWorkPending | null {
  if (!current || current.dismissed) return null;
  const v = Math.max(0, Math.min(99, Math.floor(Number(n) || 0)));
  if (current.running_agents === v) return current;
  current.running_agents = v;
  save();
  return current;
}

export function getById(id: string): EndWorkPending | null {
  if (current && current.id === id) return { ...current };
  return resolved.get(id)?.entry ?? null;
}

/** Touch-dismiss from the CYD. Returns the cleared entry or null. */
export function dismissEndWork(id: string): EndWorkPending | null {
  const p = getPending();
  if (!p || p.id !== id) return null;
  p.dismissed = true;
  const done = { ...p };
  remember(done);
  current = null;
  save();
  return done;
}

export function hasPending(): boolean {
  return getPending() !== null;
}

/** Test hook: drop the slot. */
export function resetEndWork(): void {
  current = null;
}
