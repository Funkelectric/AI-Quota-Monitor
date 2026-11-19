/** Native Node HTTP transport: GET /api/quota, GET /api/ask, POST /api/ask*, GET /health */
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { answerAsk, getById, getPending, hasPending, postAsk } from "../askStore.js";
import type { QuotaPayload } from "../types.js";

export interface HttpOptions {
  host: string;
  port: number;
  getPayload: () => QuotaPayload | Promise<QuotaPayload>;
}

const BODY_MAX = 4096;

function readJson(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let n = 0;
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => {
      n += c.length;
      if (n > BODY_MAX) {
        reject(new Error("body_too_large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"));
      } catch (err) {
        reject(err);
      }
    });
    req.on("error", reject);
  });
}

function send(res: ServerResponse, code: number, obj: unknown): void {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
  });
  res.end(body);
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
      const body = JSON.stringify({ ok: true, ts: Math.floor(Date.now() / 1000), ask_pending: hasPending() });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(body);
      return;
    }

    if (req.method === "GET" && url.pathname === "/api/ask") {
      // ?id= returns that question's state (pending or recently answered).
      const qid = url.searchParams.get("id");
      if (qid) {
        const found = getById(qid);
        if (!found) {
          res.writeHead(410);
          res.end(JSON.stringify({ error: "gone" }));
          return;
        }
        send(res, 200, found);
        return;
      }
      const p = getPending();
      if (!p) {
        res.writeHead(204);
        res.end();
        return;
      }
      send(res, 200, p);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/ask") {
      try {
        const input = (await readJson(req)) as {
          question?: string;
          options?: (string | { id?: string; label?: string })[];
          session?: string;
          detail?: string;
          timeout_sec?: number;
        };
        if (!input || typeof input.question !== "string" || !Array.isArray(input.options)) {
          send(res, 400, { error: "bad_request", detail: "need {question: string, options: []}" });
          return;
        }
        send(res, 200, postAsk(input));
      } catch {
        send(res, 400, { error: "bad_json" });
      }
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/ask/answer") {
      try {
        const input = (await readJson(req)) as { id?: string; option_id?: string };
        const done = input?.id ? answerAsk(String(input.id), String(input.option_id ?? "")) : null;
        if (!done) {
          send(res, 410, { error: "no_such_question" });
          return;
        }
        send(res, 200, { ok: true, id: done.id, answer: done.answer });
      } catch {
        send(res, 400, { error: "bad_json" });
      }
      return;
    }

    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "not_found" }));
  });

  server.listen(opts.port, opts.host);
  return server;
}
