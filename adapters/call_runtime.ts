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
import { readRowSet, writeParams, frame_max, QueryMode } from "../generated/serde.ts";

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
  queryId: number,
  sql: string,
  mode: number,
  params: unknown[],
): Uint8Array {
  const sqlBytes = _encoder.encode(sql);
  // tag(1) + req_id(4) + query_id(2) + sql_len(2) + sql + mode(1) + param_count(1) + params
  // Param size: worst case is text/blob with up to cell_value_max bytes (1 + 2 + 4096).
  // Use a generous estimate: 256 bytes per param covers most practical cases.
  const buf = new Uint8Array(1 + 4 + 2 + 2 + sqlBytes.length + 1 + 1 + params.length * 256);
  const dv = new DataView(buf.buffer);
  let pos = 0;

  buf[pos] = CallTag.query;
  pos += 1;
  dv.setUint32(pos, requestId, false);
  pos += 4;
  dv.setUint16(pos, queryId, false);
  pos += 2;
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
// Server listens on the unix socket. Sidecar connects to it.

let pending = Buffer.alloc(0);

const conn = net.createConnection(socketPath, () => {
  console.log("[call_runtime] connected to", socketPath);
});

conn.on("data", (chunk: Buffer) => {
  pending = Buffer.concat([pending, chunk]);
  processFrames();
});

conn.on("error", (err: any) => {
  console.error("[call_runtime] error:", err.message);
  process.exit(1);
});

conn.on("close", () => {
  console.log("[call_runtime] disconnected");
  process.exit(0);
});

// --- Frame processing ---
//
// Two kinds of incoming frames:
// - CALL: start an async handler (one at a time — serial pipeline)
// - QUERY_RESULT: resolve a pending db.query() promise
//
// When a handler calls await db.query(), it sends a QUERY frame and
// suspends. The event loop is free to read more socket data. When
// QUERY_RESULT arrives, the pending promise resolves, the handler
// resumes. This is Node's async model working naturally.

let handlerInProgress = false;
const pendingQueries = new Map<number, (data: any) => void>();
let nextQueryId = 0;

function processFrames(): void {
  while (pending.length >= 4) {
    const frameLen = pending.readUInt32BE(0);
    if (pending.length < 4 + frameLen) break;
    // Copy frame data — must not alias pending buffer. When async
    // handlers suspend (await db.query), more data arrives and
    // Buffer.concat replaces the buffer. The old view would be stale.
    const frame = new Uint8Array(pending.buffer.slice(
      pending.byteOffset + 4,
      pending.byteOffset + 4 + frameLen,
    ));
    pending = pending.subarray(4 + frameLen);

    const tag = frame[0];

    if (tag === CallTag.query_result) {
      // QUERY_RESULT — resolve the pending db.query() promise.
      handleQueryResult(frame);
    } else if (tag === CallTag.call) {
      if (handlerInProgress) {
        console.error("[call_runtime] CALL received while handler in progress");
        conn.destroy();
        return;
      }
      // Fire-and-forget — the async handler runs on the event loop.
      handleCall(frame);
    } else {
      console.error("[call_runtime] unexpected tag:", tag);
      conn.destroy();
      return;
    }
  }
}

function handleQueryResult(frame: Uint8Array): void {
  // Parse: [tag: u8][request_id: u32 BE][query_id: u16 BE][row_set...]
  const dv = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  const queryId = dv.getUint16(5, false);
  const rowSetData = frame.subarray(7); // skip tag + request_id + query_id

  const resolve = pendingQueries.get(queryId);
  if (!resolve) {
    console.error("[call_runtime] QUERY_RESULT for unknown query_id:", queryId);
    conn.destroy();
    return;
  }
  pendingQueries.delete(queryId);

  if (rowSetData.length === 0) {
    resolve(null);
  } else if (rowSetData.length < 6) {
    // Too short for a valid row set (col_count(2) + at least one col + row_count(4))
    console.error("[call_runtime] QUERY_RESULT too short:", rowSetData.length, "bytes");
    resolve(null);
  } else {
    try {
      const rowSetDv = new DataView(rowSetData.buffer, rowSetData.byteOffset, rowSetData.byteLength);
      const { result } = readRowSet(rowSetDv, 0);
      resolve(result);
    } catch (e: any) {
      const hex = Array.from(rowSetData.subarray(0, Math.min(32, rowSetData.length)))
        .map(b => b.toString(16).padStart(2, '0')).join(' ');
      console.error(`[call_runtime] QUERY_RESULT parse error: ${e.message}, len=${rowSetData.length}, hex=[${hex}]`);
      resolve(null);
    }
  }
}

async function handleCall(frame: Uint8Array): Promise<void> {
  handlerInProgress = true;

  const dv = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  const requestId = dv.getUint32(1, false);
  const nameLen = dv.getUint16(5, false);
  const name = _decoder.decode(frame.subarray(7, 7 + nameLen));
  const args = frame.subarray(7 + nameLen);

  try {
    switch (name) {
      case "route":
        dispatchRoute(requestId, args);
        break;
      case "prefetch":
        await dispatchPrefetch(requestId, args);
        break;
      case "handle":
        dispatchHandle(requestId, args);
        break;
      case "render":
        await dispatchRender(requestId, args);
        break;
      default:
        console.error("[call_runtime] unknown function:", name);
        sendFrame(conn, buildResult(requestId, ResultFlag.failure, new Uint8Array(0)));
    }
  } catch (e: any) {
    console.error(`[call_runtime] ${name} error:`, e.message || e);
    sendFrame(conn, buildResult(requestId, ResultFlag.failure, new Uint8Array(0)));
  } finally {
    handlerInProgress = false;
  }
}

// --- Route CALL ---
// Args: [method: u8][path_len: u16 BE][path][body_len: u16 BE][body]
// Result: [found: u8][operation: u8][id: u128 BE]

import { matchRoute } from "../generated/routing.ts";

function parseQueryParam(queryString: string, name: string): string | null {
  const params = new URLSearchParams(queryString);
  return params.get(name);
}
import { OperationValues } from "../generated/types.generated.ts";

// Route table — inline for now. Scanner will generate this.
interface RouteTableEntry { operation: string; method: string; pattern: string; query_params: string[]; }
const routeTable: RouteTableEntry[] = [
  { operation: 'remove_collection_member', method: 'delete', pattern: '/collections/:id/members/:sub_id', query_params: [] },
  { operation: 'delete_collection', method: 'delete', pattern: '/collections/:id', query_params: [] },
  { operation: 'delete_product', method: 'delete', pattern: '/products/:id', query_params: [] },
  { operation: 'get_collection', method: 'get', pattern: '/collections/:id', query_params: [] },
  { operation: 'get_order', method: 'get', pattern: '/orders/:id', query_params: [] },
  { operation: 'get_product', method: 'get', pattern: '/products/:id', query_params: [] },
  { operation: 'get_product_inventory', method: 'get', pattern: '/products/:id/inventory', query_params: [] },
  { operation: 'list_collections', method: 'get', pattern: '/collections', query_params: [] },
  { operation: 'list_orders', method: 'get', pattern: '/orders', query_params: [] },
  { operation: 'list_products', method: 'get', pattern: '/products', query_params: [] },
  { operation: 'page_load_dashboard', method: 'get', pattern: '/', query_params: [] },
  { operation: 'page_load_login', method: 'get', pattern: '/login', query_params: [] },
  { operation: 'search_products', method: 'get', pattern: '/products', query_params: ['q'] },
  { operation: 'add_collection_member', method: 'post', pattern: '/collections/:id/members', query_params: [] },
  { operation: 'cancel_order', method: 'post', pattern: '/orders/:id/cancel', query_params: [] },
  { operation: 'complete_order', method: 'post', pattern: '/orders/:id/complete', query_params: [] },
  { operation: 'create_collection', method: 'post', pattern: '/collections', query_params: [] },
  { operation: 'create_order', method: 'post', pattern: '/orders', query_params: [] },
  { operation: 'create_product', method: 'post', pattern: '/products', query_params: [] },
  { operation: 'logout', method: 'post', pattern: '/logout', query_params: [] },
  { operation: 'request_login_code', method: 'post', pattern: '/login/request', query_params: [] },
  { operation: 'transfer_inventory', method: 'post', pattern: '/products/:id/transfer', query_params: [] },
  { operation: 'verify_login_code', method: 'post', pattern: '/login/verify', query_params: [] },
  { operation: 'update_product', method: 'put', pattern: '/products/:id', query_params: [] },
];

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

async function dispatchPrefetch(requestId: number, args: Uint8Array): Promise<void> {
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

  // db.query() sends QUERY frame, returns Promise that resolves when
  // QUERY_RESULT arrives. The handler awaits it — Node's event loop
  // processes socket data while the handler is suspended.
  const db = {
    query: (sql: string, ...params: unknown[]) => {
      return queryServerAsync(requestId, sql, QueryMode.query, params);
    },
    queryAll: (sql: string, ...params: unknown[]) => {
      return queryServerAsync(requestId, sql, QueryMode.queryAll, params);
    },
  };

  const prefetched = await mod.prefetch(msg, db);
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

import { StatusNames } from "../generated/types.generated.ts";

async function dispatchRender(requestId: number, args: Uint8Array): Promise<void> {
  const statusValue = args[1];
  const statusName = (StatusNames as any)[statusValue] || "ok";

  const mod = modules[requestState.operation];
  if (!mod?.render) {
    sendFrame(conn, buildResult(requestId, ResultFlag.success, new Uint8Array(0)));
    resetRequestState();
    return;
  }

  const db = {
    query: (sql: string, ...params: unknown[]) => {
      return queryServerAsync(requestId, sql, QueryMode.query, params);
    },
    queryAll: (sql: string, ...params: unknown[]) => {
      return queryServerAsync(requestId, sql, QueryMode.queryAll, params);
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

  const html = (await mod.render(ctx, db)) || "";
  const htmlBytes = _encoder.encode(html);

  sendFrame(conn, buildResult(requestId, ResultFlag.success, htmlBytes));

  // Request complete — reset state.
  resetRequestState();
}

// --- QUERY sub-protocol ---
// Send QUERY frame, return Promise. The Promise resolves when
// QUERY_RESULT arrives on the socket. The event loop processes
// socket data while the handler is suspended.
//
// Serial pipeline: at most one pending QUERY at a time. The handler
// awaits db.query() sequentially. Parallel queries via Promise.all()
// would require multiple pending resolvers — not supported yet.

async function queryServerAsync(
  requestId: number,
  sql: string,
  mode: number,
  params: unknown[],
): Promise<any> {
  // Assign a unique query_id for this QUERY. Enables Promise.all() —
  // multiple queries in flight, each matched to its QUERY_RESULT.
  const queryId = nextQueryId++;
  if (nextQueryId > 0xFFFF) nextQueryId = 0; // wrap u16

  // Send QUERY frame with query_id.
  const queryFrame = buildQuery(requestId, queryId, sql, mode, params);
  sendFrame(conn, queryFrame);

  // Wait for QUERY_RESULT with matching query_id.
  return new Promise<any>((resolve) => {
    pendingQueries.set(queryId, (rowSet) => {
      if (rowSet === null) {
        resolve(mode === QueryMode.queryAll ? [] : null);
      } else if (mode === QueryMode.query) {
        resolve(rowSet.rows.length > 0 ? rowSet.rows[0] : null);
      } else {
        resolve(rowSet.rows);
      }
    });
  });
}
