/** Native Node HTTP transport: GET /api/quota, GET /api/ask, POST /api/ask*, GET /health */
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { answerAsk, getById, getPending, hasPending, postAsk } from "../askStore.js";
import { dismissEndWork, getById as getEndById, getPending as getEndPending, hasPending as hasEndPending, postEndWork } from "../endWorkStore.js";
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

/**
 * Optional bearer gate for mutating routes (AUDIT P3-17, PLAN-CYD-ASK §3.2).
 * LAN-open by default (documented); set CYD_TOKEN to require
 * `Authorization: Bearer <token>` on POST /api/ask and POST /api/ask/answer.
 * GETs stay open so the CYD poll loop never needs secrets in flash.
 */
function checkAuth(req: IncomingMessage): boolean {
  const want = (process.env.CYD_TOKEN ?? "").trim();
  if (!want) return true;
  const got = (req.headers.authorization ?? "").trim();
  return got === `Bearer ${want}`;
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
      const body = JSON.stringify({ ok: true, ts: Math.floor(Date.now() / 1000), ask_pending: hasPending(), endwork_pending: hasEndPending() });
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
      if (!checkAuth(req)) {
        send(res, 401, { error: "unauthorized" });
        return;
      }
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
      if (!checkAuth(req)) {
        send(res, 401, { error: "unauthorized" });
        return;
      }
      try {
        const input = (await readJson(req)) as { id?: string; option_id?: string };
        const done = input?.id ? answerAsk(String(input.id), String(input.option_id ?? "")) : null;
        if (!done) {
          // Distinguish unknown question (410 gone) from known PENDING
          // question + unknown option (400 bad_option). Never silently
          // record options[0]. Note: getById() also matches resolved
          // entries — replay of an answered question must stay 410, so only
          // the live pending slot yields 400.
          const pend = getPending();
          if (pend && input?.id && pend.id === String(input.id)) send(res, 400, { error: "bad_option" });
          else send(res, 410, { error: "no_such_question" });
          return;
        }
        send(res, 200, { ok: true, id: done.id, answer: done.answer });
      } catch {
        send(res, 400, { error: "bad_json" });
      }
      return;
    }

    if (req.method === "GET" && url.pathname === "/api/endofwork") {
      const qid = url.searchParams.get("id");
      if (qid) {
        const found = getEndById(qid);
        if (!found) {
          res.writeHead(410);
          res.end(JSON.stringify({ error: "gone" }));
          return;
        }
        send(res, 200, found);
        return;
      }
      const p = getEndPending();
      if (!p) {
        res.writeHead(204);
        res.end();
        return;
      }
      send(res, 200, p);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/endofwork") {
      if (!checkAuth(req)) {
        send(res, 401, { error: "unauthorized" });
        return;
      }
      try {
        const input = (await readJson(req)) as {
          title?: string;
          model?: string;
          session?: string;
        };
        if (!input || typeof input.title !== "string") {
          send(res, 400, { error: "bad_request", detail: "need {title: string}" });
          return;
        }
        send(res, 200, postEndWork(input));
      } catch {
        send(res, 400, { error: "bad_json" });
      }
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/endofwork/dismiss") {
      if (!checkAuth(req)) {
        send(res, 401, { error: "unauthorized" });
        return;
      }
      try {
        const input = (await readJson(req)) as { id?: string };
        const done = input?.id ? dismissEndWork(String(input.id)) : null;
        if (!done) {
          send(res, 410, { error: "no_such_event" });
          return;
        }
        send(res, 200, { ok: true, id: done.id });
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
