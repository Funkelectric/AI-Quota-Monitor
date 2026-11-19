/**
 * Single-slot question queue for the CYD 05 · ASK screen.
 * One pending question at a time; a new POST replaces the old waiter.
 * Expiry is lazy (checked on read) so no timer is needed.
 */

export interface AskOption {
  id: string;
  label: string;
}

export interface AskPending {
  id: string;
  ts: number;
  session: string;
  question: string;
  detail: string;
  options: AskOption[];
  timeout_sec: number;
  answered: boolean;
  answer?: string;
}

let current: AskPending | null = null;

/** Recently resolved (answered or expired) entries, so the asker can fetch the answer by id. */
const resolved = new Map<string, { entry: AskPending; at: number }>();

function remember(entry: AskPending): void {
  resolved.set(entry.id, { entry: { ...entry }, at: Date.now() });
  // Prune entries older than 5 min.
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

function rid(): string {
  return `q_${Date.now().toString(36)}${Math.floor(Math.random() * 0xffff).toString(36)}`;
}

const MAX_Q = 120;
const MAX_LABEL = 24;
const MAX_OPTS = 4;

export function postAsk(input: {
  question?: string;
  options?: (string | { id?: string; label?: string })[];
  session?: string;
  detail?: string;
  timeout_sec?: number;
}): AskPending {
  const question = String(input.question ?? "").slice(0, MAX_Q) || "Continue?";
  const rawOpts = Array.isArray(input.options) ? input.options : [];
  const options: AskOption[] = rawOpts.slice(0, MAX_OPTS).map((o, i) => {
    if (typeof o === "string") return { id: `opt${i + 1}`, label: o.slice(0, MAX_LABEL) || `Option ${i + 1}` };
    const label = String(o?.label ?? "").slice(0, MAX_LABEL) || `Option ${i + 1}`;
    const id = String(o?.id ?? "").slice(0, 16) || `opt${i + 1}`;
    return { id, label };
  });
  while (options.length === 0) options.push({ id: "opt1", label: "OK" });
  let timeout_sec = Math.round(Number(input.timeout_sec ?? 90));
  if (!Number.isFinite(timeout_sec) || timeout_sec < 10) timeout_sec = 10;
  if (timeout_sec > 300) timeout_sec = 300;
  const entry: AskPending = {
    id: rid(),
    ts: Math.floor(Date.now() / 1000),
    session: String(input.session ?? "").slice(0, 23),
    question,
    detail: String(input.detail ?? "").slice(0, 48),
    options,
    timeout_sec,
    answered: false,
  };
  current = entry;
  return entry;
}

/** Pending question, or null when none / expired / already answered. */
export function getPending(): AskPending | null {
  if (!current) return null;
  if (current.answered) return null;
  if (Date.now() / 1000 - current.ts > current.timeout_sec) {
    remember({ ...current });
    current = null;
    return null;
  }
  return current;
}

/** Fetch any known question by id: pending or recently resolved (with answer). */
export function getById(id: string): AskPending | null {
  const p = getPending();
  if (p && p.id === id) return p;
  if (current && current.id === id) return { ...current };
  return resolved.get(id)?.entry ?? null;
}

export function answerAsk(id: string, option_id: string): AskPending | null {
  const p = getPending();
  if (!p || p.id !== id) return null;
  const opt = p.options.find((o) => o.id === option_id) ?? p.options[0];
  p.answered = true;
  p.answer = opt.id;
  const done = { ...p };
  remember(done);
  current = null;
  return done;
}

export function hasPending(): boolean {
  return getPending() !== null;
}
