// CALL/RESULT sidecar runtime — dumb function executor.
//
// Connects to the server's unix socket. Receives CALL frames, dispatches
// to handler functions, sends RESULT frames. QUERY sub-protocol for
// db.query() in prefetch and render.
//
// This is the reference implementation. Other languages reimplement
// the spec (four frame types over a unix socket).
//
// Usage: npx tsx generated/call_runtime.ts <socket-path>

import * as net from "net";
import { readRowSet, writeParams, frame_max, QueryMode } from "./serde.ts";

// --- Protocol constants (match protocol.zig) ---

const CallTag = {
  call: 0x10,
  result: 0x11,
  query: 0x12,
  query_result: 0x13,
} as const;

const ResultFlag = {
  success: 0x00,
  failure: 0x01,
} as const;

const Methods = ["get", "put", "post", "delete"] as const;

// --- Handler registry ---

interface HandlerModule {
  route?: (req: any) => any | null;
  prefetch?: (msg: any, db: any) => any;
  handle?: (ctx: any, db: any) => string;
  render?: (ctx: any, db?: any) => string;
}

const handlers: Record<string, HandlerModule> = {};

// Import all handler modules. The scanner will generate this list.
// For now, import the ecommerce example handlers.
import * as getProduct from "../examples/ecommerce-ts/handlers/get_product.ts";
import * as createProduct from "../examples/ecommerce-ts/handlers/create_product.ts";
import * as listProducts from "../examples/ecommerce-ts/handlers/list_products.ts";
import * as updateProduct from "../examples/ecommerce-ts/handlers/update_product.ts";
import * as deleteProduct from "../examples/ecommerce-ts/handlers/delete_product.ts";
import * as getProductInventory from "../examples/ecommerce-ts/handlers/get_product_inventory.ts";
import * as searchProducts from "../examples/ecommerce-ts/handlers/search_products.ts";
import * as transferInventory from "../examples/ecommerce-ts/handlers/transfer_inventory.ts";
import * as createCollection from "../examples/ecommerce-ts/handlers/create_collection.ts";
import * as getCollection from "../examples/ecommerce-ts/handlers/get_collection.ts";
import * as listCollections from "../examples/ecommerce-ts/handlers/list_collections.ts";
import * as deleteCollection from "../examples/ecommerce-ts/handlers/delete_collection.ts";
import * as addCollectionMember from "../examples/ecommerce-ts/handlers/add_collection_member.ts";
import * as removeCollectionMember from "../examples/ecommerce-ts/handlers/remove_collection_member.ts";
import * as createOrder from "../examples/ecommerce-ts/handlers/create_order.ts";
import * as getOrder from "../examples/ecommerce-ts/handlers/get_order.ts";
import * as listOrders from "../examples/ecommerce-ts/handlers/list_orders.ts";
import * as completeOrder from "../examples/ecommerce-ts/handlers/complete_order.ts";
import * as cancelOrder from "../examples/ecommerce-ts/handlers/cancel_order.ts";
import * as pageLoadDashboard from "../examples/ecommerce-ts/handlers/page_load_dashboard.ts";
import * as pageLoadLogin from "../examples/ecommerce-ts/handlers/page_load_login.ts";
import * as requestLoginCode from "../examples/ecommerce-ts/handlers/request_login_code.ts";
import * as verifyLoginCode from "../examples/ecommerce-ts/handlers/verify_login_code.ts";
import * as logout from "../examples/ecommerce-ts/handlers/logout.ts";

// Register by operation name — matches the function_name in CALL frames.
const modules: Record<string, HandlerModule> = {
  get_product: getProduct,
  create_product: createProduct,
  list_products: listProducts,
  update_product: updateProduct,
  delete_product: deleteProduct,
  get_product_inventory: getProductInventory,
  search_products: searchProducts,
  transfer_inventory: transferInventory,
  create_collection: createCollection,
  get_collection: getCollection,
  list_collections: listCollections,
  delete_collection: deleteCollection,
  add_collection_member: addCollectionMember,
  remove_collection_member: removeCollectionMember,
  create_order: createOrder,
  get_order: getOrder,
  list_orders: listOrders,
  complete_order: completeOrder,
  cancel_order: cancelOrder,
  page_load_dashboard: pageLoadDashboard,
  page_load_login: pageLoadLogin,
  request_login_code: requestLoginCode,
  verify_login_code: verifyLoginCode,
  logout: logout,
};

// --- Frame IO ---

const _decoder = new TextDecoder();
const _encoder = new TextEncoder();

function sendFrame(conn: net.Socket, payload: Uint8Array): void {
  const header = Buffer.alloc(4);
  header.writeUInt32BE(payload.length, 0);
  conn.write(header);
  if (payload.length > 0) conn.write(payload);
}

function buildResult(
  requestId: number,
  flag: number,
  data: Uint8Array,
): Uint8Array {
  const buf = new Uint8Array(1 + 4 + 1 + data.length);
  const dv = new DataView(buf.buffer);
  buf[0] = CallTag.result;
  dv.setUint32(1, requestId, false);
  buf[5] = flag;
  buf.set(data, 6);
  return buf;
}

function buildQuery(
  requestId: number,
  sql: string,
  mode: number,
  params: unknown[],
): Uint8Array {
  const sqlBytes = _encoder.encode(sql);
  // Estimate buffer size: tag(1) + req_id(4) + sql_len(2) + sql + mode(1) + param_count(1) + params
  const buf = new Uint8Array(1 + 4 + 2 + sqlBytes.length + 1 + 1 + params.length * 20);
  const dv = new DataView(buf.buffer);
  let pos = 0;

  buf[pos] = CallTag.query;
  pos += 1;
  dv.setUint32(pos, requestId, false);
  pos += 4;
  dv.setUint16(pos, sqlBytes.length, false);
  pos += 2;
  buf.set(sqlBytes, pos);
  pos += sqlBytes.length;
  buf[pos] = mode;
  pos += 1;
  buf[pos] = params.length;
  pos += 1;
  pos += writeParams(dv, pos, params);

  return buf.subarray(0, pos);
}

// --- Per-request state (sidecar holds between CALLs) ---

interface RequestState {
  operation: string;
  id: string;
  body: Record<string, any>;
  params: Record<string, string>;
  prefetched: Record<string, any>;
}

let requestState: RequestState = {
  operation: "",
  id: "",
  body: {},
  params: {},
  prefetched: {},
};

function resetRequestState(): void {
  requestState = { operation: "", id: "", body: {}, params: {}, prefetched: {} };
}

// --- Socket path ---

const socketPath = process.argv[2];
if (!socketPath) {
  console.error("Usage: npx tsx generated/call_runtime.ts <socket-path>");
  process.exit(1);
}

// --- Connect to server ---
// The server listens, the sidecar connects. Reverse of the old protocol.

const conn = net.createConnection(socketPath, () => {
  console.log("[call_runtime] connected to", socketPath);
});

let pending = Buffer.alloc(0);

conn.on("data", (chunk: Buffer) => {
  pending = Buffer.concat([pending, chunk]);
  processFrames();
});

conn.on("error", (err) => {
  console.error("[call_runtime] connection error:", err.message);
  process.exit(1);
});

conn.on("close", () => {
  console.log("[call_runtime] disconnected");
  process.exit(0);
});

// --- Frame processing ---

function processFrames(): void {
  while (pending.length >= 4) {
    const frameLen = pending.readUInt32BE(0);
    if (pending.length < 4 + frameLen) break;
    const frame = new Uint8Array(
      pending.buffer,
      pending.byteOffset + 4,
      frameLen,
    );
    pending = pending.subarray(4 + frameLen);
    handleFrame(frame);
  }
}

function handleFrame(frame: Uint8Array): void {
  if (frame.length < 7) {
    console.error("[call_runtime] frame too short");
    conn.destroy();
    return;
  }

  const tag = frame[0];
  if (tag !== CallTag.call) {
    console.error("[call_runtime] unexpected tag:", tag);
    conn.destroy();
    return;
  }

  const dv = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  const requestId = dv.getUint32(1, false);
  const nameLen = dv.getUint16(5, false);
  const name = _decoder.decode(frame.subarray(7, 7 + nameLen));
  const args = frame.subarray(7 + nameLen);

  try {
    dispatch(name, requestId, args, dv);
  } catch (e: any) {
    console.error(`[call_runtime] ${name} error:`, e.message || e);
    sendFrame(conn, buildResult(requestId, ResultFlag.failure, new Uint8Array(0)));
  }
}

// --- Dispatch ---

function dispatch(
  name: string,
  requestId: number,
  args: Uint8Array,
  _dv: DataView,
): void {
  switch (name) {
    case "route":
      dispatchRoute(requestId, args);
      break;
    case "prefetch":
      dispatchPrefetch(requestId, args);
      break;
    case "handle":
      dispatchHandle(requestId, args);
      break;
    case "render":
      dispatchRender(requestId, args);
      break;
    default:
      console.error("[call_runtime] unknown function:", name);
      sendFrame(conn, buildResult(requestId, ResultFlag.failure, new Uint8Array(0)));
  }
}

// --- Route CALL ---
// Args: [method: u8][path_len: u16 BE][path][body_len: u16 BE][body]
// Result: [found: u8][operation: u8][id: u128 BE]

import { matchRoute, parseQueryParam } from "./routing.ts";
import { OperationValues } from "./types.generated.ts";

// Route table — same as dispatch.generated.ts. Will be scanner-generated.
import type { RouteTableEntry } from "./routing.ts";

// Import route table from the generated dispatch (temporary — shared source of truth).
// TODO: scanner generates this directly into call_runtime.
const routeTable: RouteTableEntry[] = (await import("./dispatch.generated.ts")).routeTable ?? [];

function dispatchRoute(requestId: number, args: Uint8Array): void {
  const dv = new DataView(args.buffer, args.byteOffset, args.byteLength);
  let pos = 0;

  const method = args[pos];
  pos += 1;
  const pathLen = dv.getUint16(pos, false);
  pos += 2;
  const path = _decoder.decode(args.subarray(pos, pos + pathLen));
  pos += pathLen;
  const bodyLen = dv.getUint16(pos, false);
  pos += 2;
  const body = _decoder.decode(args.subarray(pos, pos + bodyLen));

  const methods = ["get", "put", "post", "delete"];
  const methodStr = methods[method] || "get";

  // Route matching — same as old dispatch.
  const queryIdx = path.indexOf("?");
  const queryString = queryIdx >= 0 ? path.slice(queryIdx + 1) : "";

  let result: any = null;
  let matchedOp = "";

  for (const entry of routeTable) {
    if (entry.method !== methodStr) continue;
    const params = matchRoute(path, entry.pattern);
    if (!params) continue;

    // Merge query params.
    for (const qname of entry.query_params) {
      const qval = parseQueryParam(queryString, qname);
      if (qval !== null) params[qname] = qval;
    }

    const routeFn = modules[entry.operation]?.route;
    if (!routeFn) continue;

    const req = { method: methodStr, path, body, params };
    const routeResult = routeFn(req);
    if (routeResult) {
      result = routeResult;
      matchedOp = entry.operation;
      break;
    }
  }

  if (!result) {
    // Not found — send result with found=0.
    sendFrame(conn, buildResult(requestId, ResultFlag.success, new Uint8Array([0])));
    return;
  }

  // Store per-request state from route.
  requestState.operation = matchedOp;
  requestState.id = result.id || "";
  requestState.body = typeof body === "string" && body.length > 0 ? JSON.parse(body) : {};
  requestState.params = result.params || {};

  // Build result: [found: u8][operation: u8][id: u128 BE]
  const opValue = (OperationValues as any)[matchedOp];
  const resultBuf = new Uint8Array(1 + 1 + 16);
  const resultDv = new DataView(resultBuf.buffer);
  resultBuf[0] = 1; // found
  resultBuf[1] = opValue;
  // ID as u128 BE — parse hex string to 16 bytes.
  const idHex = (result.id || "0".repeat(32)).padStart(32, "0");
  for (let i = 0; i < 16; i++) {
    resultBuf[2 + i] = parseInt(idHex.substr(i * 2, 2), 16);
  }

  sendFrame(conn, buildResult(requestId, ResultFlag.success, resultBuf));
}

// --- Prefetch CALL ---
// Args: [operation: u8][id: u128 BE]
// QUERY sub-protocol for db.query()
// Result: empty (sidecar holds state)

function dispatchPrefetch(requestId: number, args: Uint8Array): void {
  const dv = new DataView(args.buffer, args.byteOffset, args.byteLength);
  const _operation = args[0];
  // ID from args — but we already have it from route.

  const mod = modules[requestState.operation];
  if (!mod?.prefetch) {
    sendFrame(conn, buildResult(requestId, ResultFlag.success, new Uint8Array(0)));
    return;
  }

  const msg = {
    operation: requestState.operation,
    id: requestState.id,
    body: requestState.body,
  };

  // db object with query/queryAll that send QUERY frames synchronously.
  // In the CALL/RESULT model, these are blocking — the sidecar waits
  // for QUERY_RESULT before continuing.
  const db = {
    query: (sql: string, ...params: unknown[]) => {
      return queryServer(requestId, sql, QueryMode.query, params);
    },
    queryAll: (sql: string, ...params: unknown[]) => {
      return queryServer(requestId, sql, QueryMode.queryAll, params);
    },
  };

  const prefetched = mod.prefetch(msg, db);
  requestState.prefetched = prefetched || {};

  sendFrame(conn, buildResult(requestId, ResultFlag.success, new Uint8Array(0)));
}

// --- Handle CALL ---
// Args: [operation: u8][id: u128 BE]
// Result: [status_len: u16 BE][status_str][write_count: u8][writes...]

function dispatchHandle(requestId: number, _args: Uint8Array): void {
  const mod = modules[requestState.operation];
  if (!mod?.handle) {
    // No handle function — return "ok" with no writes.
    const statusBytes = _encoder.encode("ok");
    const resultBuf = new Uint8Array(2 + statusBytes.length + 1);
    const resultDv = new DataView(resultBuf.buffer);
    resultDv.setUint16(0, statusBytes.length, false);
    resultBuf.set(statusBytes, 2);
    resultBuf[2 + statusBytes.length] = 0; // write_count
    sendFrame(conn, buildResult(requestId, ResultFlag.success, resultBuf));
    return;
  }

  // Build ctx.
  const writes: Array<{ sql: string; params: unknown[] }> = [];
  const db = {
    execute: (sql: string, ...params: unknown[]) => {
      writes.push({ sql, params });
    },
  };

  const ctx = {
    operation: requestState.operation,
    id: requestState.id,
    body: requestState.body,
    params: requestState.params,
    prefetched: requestState.prefetched,
  };

  const status = mod.handle(ctx, db) || "ok";

  // Build result: [status_len: u16 BE][status_str][write_count: u8][writes...]
  const statusBytes = _encoder.encode(status);
  // Calculate total write size.
  let writeSize = 0;
  for (const w of writes) {
    const sqlBytes = _encoder.encode(w.sql);
    // [sql_len: u16 BE][sql][param_count: u8][params...]
    writeSize += 2 + sqlBytes.length + 1;
    // Estimate param size.
    for (const p of w.params) {
      if (p === null || p === undefined) writeSize += 1;
      else if (typeof p === "number") writeSize += 9;
      else if (typeof p === "boolean") writeSize += 9;
      else if (typeof p === "string") writeSize += 3 + _encoder.encode(String(p)).length;
      else if (typeof p === "bigint") writeSize += 9;
      else if (p instanceof Uint8Array) writeSize += 3 + p.length;
      else writeSize += 1;
    }
  }

  const resultBuf = new Uint8Array(2 + statusBytes.length + 1 + writeSize);
  const resultDv = new DataView(resultBuf.buffer);
  let pos = 0;

  resultDv.setUint16(pos, statusBytes.length, false);
  pos += 2;
  resultBuf.set(statusBytes, pos);
  pos += statusBytes.length;
  resultBuf[pos] = writes.length;
  pos += 1;

  for (const w of writes) {
    const sqlBytes = _encoder.encode(w.sql);
    resultDv.setUint16(pos, sqlBytes.length, false);
    pos += 2;
    resultBuf.set(sqlBytes, pos);
    pos += sqlBytes.length;
    resultBuf[pos] = w.params.length;
    pos += 1;
    pos += writeParams(resultDv, pos, w.params);
  }

  sendFrame(conn, buildResult(requestId, ResultFlag.success, resultBuf.subarray(0, pos)));
}

// --- Render CALL ---
// Args: [operation: u8][status: u8]
// QUERY sub-protocol for db.query()
// Result: raw HTML bytes

import { StatusNames } from "./types.generated.ts";

function dispatchRender(requestId: number, args: Uint8Array): void {
  const _operation = args[0];
  const statusValue = args[1];
  const statusName = (StatusNames as any)[statusValue] || "ok";

  const mod = modules[requestState.operation];
  if (!mod?.render) {
    sendFrame(conn, buildResult(requestId, ResultFlag.success, new Uint8Array(0)));
    return;
  }

  const db = {
    query: (sql: string, ...params: unknown[]) => {
      return queryServer(requestId, sql, QueryMode.query, params);
    },
    queryAll: (sql: string, ...params: unknown[]) => {
      return queryServer(requestId, sql, QueryMode.queryAll, params);
    },
  };

  const ctx = {
    operation: requestState.operation,
    id: requestState.id,
    status: statusName,
    body: requestState.body,
    params: requestState.params,
    prefetched: requestState.prefetched,
    is_sse: false,
  };

  const html = mod.render(ctx, db) || "";
  const htmlBytes = _encoder.encode(html);

  sendFrame(conn, buildResult(requestId, ResultFlag.success, htmlBytes));

  // Request complete — reset state.
  resetRequestState();
}

// --- QUERY sub-protocol ---
// Send QUERY frame, block until QUERY_RESULT arrives.
// Synchronous from the handler's perspective.

function queryServer(
  requestId: number,
  sql: string,
  mode: number,
  params: unknown[],
): any {
  // Send QUERY frame.
  const queryFrame = buildQuery(requestId, sql, mode, params);
  sendFrame(conn, queryFrame);

  // Block until QUERY_RESULT arrives.
  // In Node.js, this requires synchronous socket reads — which aren't
  // natively supported. For the initial implementation, we use a
  // synchronous read workaround.
  //
  // TODO: This needs to be async (await). The prefetch/render functions
  // should be async, and db.query() returns a promise. The frame
  // processing loop needs to handle interleaved QUERY_RESULT frames.
  //
  // For now, return a placeholder — the sync read problem needs to be
  // solved before this works end-to-end.
  throw new Error("QUERY sub-protocol requires async implementation — see TODO");
}
