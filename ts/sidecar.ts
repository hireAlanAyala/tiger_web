// Minimal sidecar — translate + execute_render.
// Run: npx tsx ts/sidecar.ts /tmp/tiger.sock

import * as net from "net";
import { unlinkSync } from "fs";
import {
  readTranslateRequest,
  writeTranslateResponse,
  readExecuteRenderRequest,
  writeExecuteRenderResponse,
  translate_request_size,
  translate_response_size,
  writeProduct,
  type TranslateRequest,
  type TranslateResponse,
  type ExecuteRenderRequest,
  type ExecuteRenderResponse,
  type Product,
  type PrefetchCache,
  StatusValues,
  TagValues,
  execute_render_request_size,
  execute_render_response_size,
} from "../generated/types.generated.ts";

const socketPath = process.argv[2];
if (!socketPath) {
  console.error("Usage: npx tsx ts/sidecar.ts <socket-path>");
  process.exit(1);
}


// --- Translate: route HTTP method + path to operation ---

function translate(req: TranslateRequest): TranslateResponse {
  const method = req.method;
  const path = req.path;

  if (method === "get" && /^\/products\/[a-f0-9]{32}$/.test(path)) {
    const id = path.slice(10);
    return { id, body: new Uint8Array(672), found: 1, operation: "get_product" };
  }

  if (method === "get" && path === "/products") {
    return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "list_products" };
  }

  if (method === "post" && path === "/products") {
    const parsed = JSON.parse(req.body || "{}");
    const product = makeProduct(parsed);
    const body = new Uint8Array(672);
    writeProduct(body, 0, product);
    return { id: product.id, body, found: 1, operation: "create_product" };
  }

  return { id: "0".repeat(32), body: new Uint8Array(672), found: 0, operation: "root" };
}

function makeProduct(parsed: Record<string, unknown>): Product {
  return {
    id: (parsed.id as string) || crypto.randomUUID().replace(/-/g, ""),
    name: (parsed.name as string) || "",
    description: (parsed.description as string) || "",
    price_cents: (parsed.price_cents as number) || 0,
    inventory: (parsed.inventory as number) || 0,
    version: 1,
    flags: { active: true },
  };
}

// --- Execute + Render: business logic + HTML ---

function executeRender(req: ExecuteRenderRequest): ExecuteRenderResponse {
  const op = req.operation;
  const cache = req.cache;

  // Minimal handler: return status ok with simple HTML for any operation.
  const html = renderHtml(op, cache);

  return {
    status: "ok",
    writes_len: 0,
    result_tag: 0,
    result: new Uint8Array(47248),
    writes: Array.from({ length: 21 }, () => ({
      tag: 0,
      reserved_tag: new Uint8Array(15),
      data: new Uint8Array(3632),
    })),
    html,
  };
}

function renderHtml(op: string, cache: PrefetchCache): string {
  if (op === "get_product" && cache.product) {
    return `<div class="product"><h1>${escapeHtml(cache.product.name)}</h1><p>$${(cache.product.price_cents / 100).toFixed(2)}</p></div>`;
  }
  if (op === "list_products") {
    const items = cache.product_list.items;
    return `<div class="products">${items.map(p => `<div>${escapeHtml(p.name)}</div>`).join("")}</div>`;
  }
  return `<div>OK</div>`;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// --- Socket server ---

const server = net.createServer((conn) => {
  console.log("[sidecar] client connected");
  let pending = Buffer.alloc(0);

  conn.on("data", (chunk: Buffer) => {
    pending = Buffer.concat([pending, chunk]);
    processMessages(conn, pending, (remaining) => { pending = remaining; });
  });

  conn.on("close", () => console.log("[sidecar] client disconnected"));
  conn.on("error", (err: Error) => console.error("[sidecar] error:", err.message));
});

function processMessages(
  conn: net.Socket,
  buf: Buffer,
  setPending: (remaining: Buffer) => void
): void {
  while (buf.length > 0) {
    // Peek at the tag byte to determine message type.
    const tag = buf[0];

    if (tag === TagValues.translate) {
      if (buf.length < translate_request_size) break;
      const reqBytes = new Uint8Array(buf.buffer, buf.byteOffset, translate_request_size);
      buf = buf.subarray(translate_request_size);

      const req = readTranslateRequest(reqBytes, 0);
      const resp = translate(req);
      const respBytes = new Uint8Array(translate_response_size);
      writeTranslateResponse(respBytes, 0, resp);
      conn.write(respBytes);
    } else if (tag === TagValues.execute_render) {
      if (buf.length < execute_render_request_size) break;
      const reqBytes = new Uint8Array(buf.buffer, buf.byteOffset, execute_render_request_size);
      buf = buf.subarray(execute_render_request_size);

      const req = readExecuteRenderRequest(reqBytes, 0);
      const resp = executeRender(req);
      const respBytes = new Uint8Array(execute_render_response_size);
      writeExecuteRenderResponse(respBytes, 0, resp);
      conn.write(respBytes);
    } else {
      console.error(`[sidecar] unknown tag: ${tag}`);
      conn.destroy();
      return;
    }
  }
  setPending(buf);
}

try { unlinkSync(socketPath); } catch {}

server.listen(socketPath, () => {
  console.log(`[sidecar] listening on ${socketPath}`);
});

process.on("SIGINT", () => {
  server.close();
  process.exit(0);
});
