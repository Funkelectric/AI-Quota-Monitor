/**
 * USB Serial transport: pushes newline-delimited JSON frames every N seconds
 * for zero-Wi-Fi desk setups (NM-CYD reads lines from Serial @ 115200).
 *
 * Frame envelope (AUDIT C4 / PLAN-CYD-ASK §3.1):
 *   {"type":"quota", ...QuotaPayload }   quota snapshot (always sent)
 *   {"type":"ask", id, question, ...}    pending question (only when pending)
 *   {"type":"ask_empty","ts":...}        clears a stale on-device question
 *
 * Firmware serialPump() routes by envelope (with backward-compat fallback to
 * raw quota payloads). Quota and ask alternate so a 2048B quota line never
 * starves a ≤1KB ask line.
 *
 * `serialport` is an optional dependency — the bridge boots fine without it
 * (or without hardware attached) and just logs a warning.
 */
import type { AskPending } from "../askStore.js";
import type { QuotaPayload } from "../types.js";

export interface SerialOptions {
  path: string;
  baudRate?: number;
  getPayload: () => QuotaPayload | Promise<QuotaPayload>;
  getAsk?: () => AskPending | Promise<AskPending | null> | null;
  intervalSec?: number;
}

interface ManagedPort {
  isOpen?: boolean;
  write(data: string, cb?: (err?: Error | null) => void): void;
  close(cb?: (err?: Error | null) => void): void;
  on(event: string, cb: (...args: unknown[]) => void): void;
}

export function startSerialPusher(opts: SerialOptions): { close(): void } {
  let closed = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let port: ManagedPort | undefined;
  let flip = false;

  async function push(): Promise<void> {
    if (closed) return;
    try {
      if (port?.isOpen) {
        let line: string;
        // Alternate quota/ask so both fit the 10s cadence without doubling
        // USB bytes. Ask frames only when pending; otherwise ask_empty
        // heartbeat every other tick keeps a stale CYD question from sticking.
        const wantAsk = flip;
        flip = !flip;
        if (wantAsk && opts.getAsk) {
          const ask = await opts.getAsk();
          if (ask) {
            line = `${JSON.stringify({ type: "ask", ...ask })}\n`;
          } else {
            line = `${JSON.stringify({ type: "ask_empty", ts: Math.floor(Date.now() / 1000) })}\n`;
          }
        } else {
          const payload = await opts.getPayload();
          line = `${JSON.stringify({ type: "quota", ...payload })}\n`;
        }
        await new Promise<void>((resolve) => {
          port?.write(line, (err) => {
            if (err) console.warn(`[serial] write failed: ${String(err).slice(0, 160)}`);
            resolve();
          });
        });
      }
    } catch (err) {
      console.warn(`[serial] push failed: ${String(err).slice(0, 160)}`);
    }
    if (!closed) timer = setTimeout(() => void push(), (opts.intervalSec ?? 10) * 1000);
  }

  (async () => {
    try {
      const mod = (await import("serialport")) as unknown as {
        SerialPort?: new (o: Record<string, unknown>) => ManagedPort;
      };
      const SerialPort = mod.SerialPort;
      if (!SerialPort) throw new Error("serialport module has no SerialPort export");
      port = new SerialPort({
        path: opts.path,
        baudRate: opts.baudRate ?? 115200,
        autoOpen: true,
      } as Record<string, unknown>);
      port.on("error", (err) => console.warn(`[serial] ${opts.path}: ${String(err).slice(0, 200)}`));
      port.on("open", () => {
        console.log(`[serial] pushing to ${opts.path} every ${opts.intervalSec ?? 10}s (quota+ask)`);
        void push();
      });
    } catch (err) {
      console.warn(
        `[serial] unavailable (${opts.path}): ${String(err).slice(0, 200)}. Install with: npm i serialport`,
      );
    }
  })();

  return {
    close() {
      closed = true;
      if (timer) clearTimeout(timer);
      try {
        port?.close(() => {});
      } catch {
        // ignore
      }
    },
  };
}
