/**
 * USB Serial transport: pushes a newline-delimited JSON frame every N seconds
 * for zero-Wi-Fi desk setups (NM-CYD reads lines from Serial @ 115200).
 *
 * `serialport` is an optional dependency — the bridge boots fine without it
 * (or without hardware attached) and just logs a warning.
 */
import type { QuotaPayload } from "../types.js";

export interface SerialOptions {
  path: string;
  baudRate?: number;
  getPayload: () => QuotaPayload | Promise<QuotaPayload>;
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

  async function push(): Promise<void> {
    if (closed) return;
    try {
      if (port?.isOpen) {
        const payload = await opts.getPayload();
        const line = `${JSON.stringify(payload)}\n`;
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
        console.log(`[serial] pushing to ${opts.path} every ${opts.intervalSec ?? 10}s`);
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
