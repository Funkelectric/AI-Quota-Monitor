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
  dismissed: boolean;
  answer?: string;
}

let current: EndWorkPending | null = null;

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
}): EndWorkPending {
  const title = String(input.title ?? "").slice(0, MAX_TITLE) || "work";
  const model = String(input.model ?? "").slice(0, MAX_MODEL);
  const session = String(input.session ?? "").slice(0, MAX_TITLE);
  const now = Math.floor(Date.now() / 1000);
  const entry: EndWorkPending = {
    id: eid(),
    ts: now,
    ended_at: now,
    title,
    model,
    session,
    dismissed: false,
  };
  current = entry;
  return entry;
}

/** Pending entry, or null when none / dismissed. */
export function getPending(): EndWorkPending | null {
  if (!current) return null;
  if (current.dismissed) return null;
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
  return done;
}

export function hasPending(): boolean {
  return getPending() !== null;
}

/** Test hook: drop the slot. */
export function resetEndWork(): void {
  current = null;
}
