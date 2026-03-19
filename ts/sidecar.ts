// Minimal sidecar — translate only.
// Run: npx tsx ts/sidecar.ts /tmp/tiger.sock

import * as net from "net";
import {
  readTranslateRequest,
  writeTranslateResponse,
  translate_request_size,
  translate_response_size,
  writeProduct,
  type TranslateRequest,
  type TranslateResponse,
  type Product,
  OperationValues,
  MethodValues,
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

  // GET /products/:id
  if (method === "get" && /^\/products\/[a-f0-9]{32}$/.test(path)) {
    const id = path.slice(10); // after "/products/"
    return { id, body: new Uint8Array(672), found: 1, operation: "get_product" };
  }

  // GET /products
  if (method === "get" && path === "/products") {
    return { id: "0".repeat(32), body: new Uint8Array(672), found: 1, operation: "list_products" };
  }

  // POST /products (create)
  if (method === "post" && path === "/products") {
    const parsed = JSON.parse(req.body || "{}");
    const product = makeProduct(parsed);
    const body = new Uint8Array(672);
    writeProduct(body, 0, product);
    return { id: product.id, body, found: 1, operation: "create_product" };
  }

  // Not found
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

// --- Socket server ---

const server = net.createServer((conn) => {
  console.log("[sidecar] client connected");
  let pending = Buffer.alloc(0);

  conn.on("data", (chunk: Buffer) => {
    pending = Buffer.concat([pending, chunk]);

    while (pending.length >= translate_request_size) {
      const reqBytes = new Uint8Array(
        pending.buffer,
        pending.byteOffset,
        translate_request_size
      );
      pending = pending.subarray(translate_request_size);

      const req = readTranslateRequest(reqBytes, 0);
      const resp = translate(req);

      const respBytes = new Uint8Array(translate_response_size);
      writeTranslateResponse(respBytes, 0, resp);
      conn.write(respBytes);
    }
  });

  conn.on("close", () => console.log("[sidecar] client disconnected"));
  conn.on("error", (err) => console.error("[sidecar] error:", err.message));
});

// Clean up stale socket file.
import { unlinkSync } from "fs";
try { unlinkSync(socketPath); } catch {}

server.listen(socketPath, () => {
  console.log(`[sidecar] listening on ${socketPath}`);
});

process.on("SIGINT", () => {
  server.close();
  process.exit(0);
});
