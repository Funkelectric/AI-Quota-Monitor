/** Native Node HTTP transport: GET /api/quota, GET /health */
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { QuotaPayload } from "../types.js";

export interface HttpOptions {
  host: string;
  port: number;
  getPayload: () => QuotaPayload | Promise<QuotaPayload>;
}

export function startHttpServer(opts: HttpOptions): Server {
  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? "/", "http://localhost");

    // CORS: allow LAN dashboard tooling to fetch freely
    res.setHeader("Access-Control-Allow-Origin", "*");

    if (req.method === "GET" && url.pathname === "/api/quota") {
      try {
        const payload = await opts.getPayload();
        const body = JSON.stringify(payload);
        res.writeHead(200, {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(body),
          "Cache-Control": "no-store",
        });
        res.end(body);
      } catch (err) {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "collector_failed", detail: String(err) }));
      }
      return;
    }

    if (req.method === "GET" && url.pathname === "/health") {
      const body = JSON.stringify({ ok: true, ts: Math.floor(Date.now() / 1000) });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(body);
      return;
    }

    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "not_found" }));
  });

  server.listen(opts.port, opts.host);
  return server;
}
