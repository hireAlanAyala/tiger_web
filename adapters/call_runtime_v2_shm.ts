// SHM sidecar runtime — 1-RT and 2-RT dispatch over shared memory.
//
// 1-RT (20/22 ops): server routes + executes prefetch SQL natively,
// sends one handle_render CALL. Sidecar runs handle + render.
// 2-RT (2 ops): server sends route_prefetch CALL, sidecar declares
// SQL, server executes, then sends handle_render CALL.
//
// Uses mmap + setImmediate polling. C addon (pollDispatch) handles
// SHM I/O, CRC, frame header parsing. JS only runs handler logic.
//
// Usage: npx tsx adapters/call_runtime_v2_shm.ts <shm-name> [slot-count]

import { ShmClient } from "./shm_client.ts";
import { modules, routeTable } from "../generated/handlers.generated.ts";
import { OperationValues } from "../generated/types.generated.ts";
import { matchRoute } from "../generated/routing.ts";
import { readRowSet } from "../generated/serde.ts";

const _decoder = new TextDecoder();
const _encoder = new TextEncoder();

const FRAME_MAX = 256 * 1024;

// Pre-computed hex lookup — avoids toString(16) + padStart per byte.
const _hexTable: string[] = new Array(256);
for (let i = 0; i < 256; i++) _hexTable[i] = i.toString(16).padStart(2, "0");

// --- Per-request state ---

interface RequestState {
  operation: string;
  id: string;
  body: any;
  params: Record<string, string>;
  rows: any[];
  status: string;
  prefetchKey: string;
  prefetchMode: "query" | "queryAll";
}

const requests = new Map<number, RequestState>();

// Pre-allocated objects for handle_render hot path — reduces GC pressure.
const _writes: Array<[string, ...any[]]> = [];
const _emptyRows: any[] = [];
const _emptyParams: Record<string, string> = {};
const _handleCtx: any = {
  operation: "", id: "", body: {}, params: _emptyParams,
  rows: _emptyRows, prefetched: {},
  write: (decl: [string, ...any[]]) => { _writes.push(decl); },
};
const _writeDb = { execute: (...a: any[]) => { _writes.push(a as any); } };
const _renderCtx: any = {
  operation: "", id: "", status: "", body: {}, params: _emptyParams,
  rows: _emptyRows, prefetched: {}, is_sse: false,
};

// Reverse map: operation int value → operation name.
const reverseOpMap: Record<number, string> = {};
for (const [name, val] of Object.entries(OperationValues)) {
  reverseOpMap[val as number] = name;
}

// Prefetch key + mode map: operation name → [{key, mode}] in query order.
// Extracted from handler source. mode determines single-row vs array.
interface PrefetchKeyInfo { key: string; mode: "query" | "queryAll"; }
const prefetchKeyMap: Record<string, PrefetchKeyInfo[]> = {};
for (const [opName, mod] of Object.entries(modules)) {
  if (!mod?.prefetch) continue;
  const src = mod.prefetch.toString();
  const infos: PrefetchKeyInfo[] = [];
  // Find all db.query / db.queryAll calls in order.
  const callRe = /db\.(query|queryAll)\s*\(/g;
  let cm;
  while ((cm = callRe.exec(src)) !== null) {
    infos.push({ key: "", mode: cm[1] === "query" ? "query" : "queryAll" });
  }
  // Extract keys from return statement.
  const m = src.match(/return\s*(?:\{|\(\s*\{)\s*([^}]+)\}/);
  if (m) {
    const parts = m[1].split(",").map(p => p.split(":")[0].trim()).filter(Boolean);
    for (let i = 0; i < Math.min(parts.length, infos.length); i++) {
      infos[i].key = parts[i];
    }
  }
  if (infos.length > 0 && infos[0].key) prefetchKeyMap[opName] = infos;
}

// --- SHM setup ---

const shmName = process.argv[2];
const slotCount = parseInt(process.argv[3] || "8", 10); // Must match pipeline_slots_max.
if (!shmName) {
  console.error("Usage: npx tsx adapters/call_runtime_v2_shm.ts <shm-name> [slot-count]");
  process.exit(1);
}
const client = new ShmClient({
  shmName,
  slotCount,
  slotDataSize: FRAME_MAX,
});

console.log(`[v2-shm] connected to ${shmName}`);

// --- Frame dispatch ---
// C addon pre-parses CALL frames: tag, request_id, function name → funcIndex.
// JS only runs handler logic. C writes RESULT back to SHM.
// funcIndex: 0=route, 1=prefetch, 2=handle, 3=render, 4=handle_render

client.setDispatchHandler((_slotIndex: number, funcIndex: number, requestId: number, args: Buffer): Uint8Array => {
  try {
    switch (funcIndex) {
      case 0: return dispatchRoute(requestId, args);
      case 1: return dispatchPrefetch(requestId, args);
      case 2: return dispatchHandle(requestId, args);
      case 3: return dispatchRender(requestId, args);
      case 4: return dispatchHandleRender(requestId, args);
      case 5: return dispatchRoutePrefetch(requestId, args);
      default: return buildResult(requestId, 0x01, new Uint8Array(0));
    }
  } catch (e: any) {
    console.error(`[v2-shm] func ${funcIndex} error:`, e.message, e.stack?.split('\n')[1] || '');
    return buildResult(requestId, 0x01, new Uint8Array(0));
  }
});

// Start polling. setImmediate gives higher throughput than futex
// under load (~15K vs ~8K) because V8 JIT stays hot between ticks.
// Futex is better for idle CPU (0% vs 100%) — use startWaiting()
// when idle efficiency matters more than peak throughput.
client.startPolling();
console.log("[v2-shm] polling started");

// --- Result builder ---
// Pre-allocated response buffer — reused across calls (single-threaded).
// Layout: [tag:1][request_id:4 BE][flag:1][payload...]
const _resultBuf = new Uint8Array(FRAME_MAX);
const _resultDv = new DataView(_resultBuf.buffer);

function buildResult(requestId: number, flag: number, data: Uint8Array): Uint8Array {
  _resultBuf[0] = 0x11; // RESULT tag
  _resultDv.setUint32(1, requestId, false);
  _resultBuf[5] = flag;
  if (data.length > 0) _resultBuf.set(data, 6);
  return _resultBuf.subarray(0, 6 + data.length);
}

// --- Route ---

function dispatchRoute(requestId: number, args: Uint8Array): Uint8Array {
  const dv = new DataView(args.buffer, args.byteOffset, args.byteLength);
  let pos = 0;
  const method = args[pos]; pos += 1;
  const pathLen = dv.getUint16(pos, false); pos += 2;
  const path = _decoder.decode(args.subarray(pos, pos + pathLen)); pos += pathLen;
  const bodyLen = dv.getUint16(pos, false); pos += 2;
  const body = _decoder.decode(args.subarray(pos, pos + bodyLen));

  const methods = ["get", "put", "post", "delete"];
  const methodStr = methods[method] || "get";
  const queryIdx = path.indexOf("?");
  const queryString = queryIdx >= 0 ? path.slice(queryIdx + 1) : "";
  const queryParams = queryString ? new URLSearchParams(queryString) : null;

  let routeResult: any = null;
  let matchedOp = "";
  for (const entry of routeTable) {
    if (entry.method !== methodStr) continue;
    const params = matchRoute(path, entry.pattern);
    if (!params) continue;
    if (queryParams) {
      for (const qname of entry.query_params) {
        const qval = queryParams.get(qname);
        if (qval !== null) params[qname] = qval;
      }
    }
    const routeFn = modules[entry.operation]?.route;
    if (!routeFn) continue;
    const req = { method: methodStr, path, body, params };
    routeResult = routeFn(req);
    if (routeResult) { matchedOp = entry.operation; break; }
  }

  if (!routeResult) return buildResult(requestId, 0x01, new Uint8Array(0));

  requests.set(requestId, {
    operation: matchedOp,
    id: (routeResult.id || "").replace(/-/g, ""),
    body: body.length > 0 ? JSON.parse(body) : {},
    params: routeResult.params || {},
    rows: [],
    status: "",
    prefetchKey: "rows",
    prefetchMode: "queryAll",
  });

  const opValue = (OperationValues as any)[matchedOp];
  const idHex = (routeResult.id || "0".repeat(32)).replace(/-/g, "").padStart(32, "0");
  const resultData = new Uint8Array(1 + 16);
  resultData[0] = opValue;
  for (let i = 0; i < 16; i++) {
    resultData[1 + i] = parseInt(idHex.substr((15 - i) * 2, 2), 16);
  }
  return buildResult(requestId, 0x00, resultData);
}

// --- Prefetch ---

function dispatchPrefetch(requestId: number, _args: Uint8Array): Uint8Array {
  const req = requests.get(requestId);
  if (!req) return buildResult(requestId, 0x01, new Uint8Array(0));

  const mod = modules[req.operation];
  if (!mod?.prefetch) return buildResult(requestId, 0x00, new Uint8Array(0));

  // Compat capture proxy for v1 async handlers.
  let capturedSql = "";
  let capturedParams: unknown[] = [];
  let captured = false;
  let capturedKey = "rows";
  let capturedMode: "query" | "queryAll" = "queryAll";
  const SENTINEL = Symbol("capture");
  const captureDb = {
    query: (sql: string, ...params: unknown[]) => { capturedSql = sql; capturedParams = params; captured = true; capturedMode = "query"; return SENTINEL; },
    queryAll: (sql: string, ...params: unknown[]) => { capturedSql = sql; capturedParams = params; captured = true; capturedMode = "queryAll"; return SENTINEL; },
  };

  const msg = { operation: req.operation, id: req.id, body: req.body, ...req.params };
  // Note: v1 handlers are async but capture proxy returns sync sentinel.
  // await resolves immediately for non-Promise values.
  const queryDecl = mod.prefetch(msg, captureDb);

  // Extract the prefetch key from the return value.
  // Sync handlers return { key: SENTINEL } directly.
  // Async handlers return a Promise — can't await in sync context.
  // For async, extract the key from the function source as fallback.
  if (queryDecl && typeof queryDecl === "object" && !Array.isArray(queryDecl) && !(queryDecl instanceof Promise)) {
    for (const [k, v] of Object.entries(queryDecl)) {
      if (v === SENTINEL) { capturedKey = k; break; }
    }
  } else if (captured && queryDecl instanceof Promise) {
    const src = mod.prefetch.toString();
    const m = src.match(/return\s*(?:\{|\(\s*\{)\s*(\w+)/);
    if (m) capturedKey = m[1];
  }
  req.prefetchKey = capturedKey;
  req.prefetchMode = capturedMode;

  let sql: string;
  let params: unknown[];
  if (captured) {
    sql = capturedSql;
    params = capturedParams;
  } else if (Array.isArray(queryDecl) && queryDecl.length > 0) {
    sql = String(queryDecl[0]);
    params = queryDecl.slice(1);
  } else {
    return buildResult(requestId, 0x00, new Uint8Array(0));
  }

  const sqlBytes = _encoder.encode(sql);
  const buf = new Uint8Array(FRAME_MAX);
  const bufDv = new DataView(buf.buffer);
  let pos = 0;
  buf[pos] = capturedMode === "query" ? 0x00 : 0x01; pos += 1;
  bufDv.setUint16(pos, sqlBytes.length, false); pos += 2;
  buf.set(sqlBytes, pos); pos += sqlBytes.length;
  buf[pos] = params.length; pos += 1;
  for (const p of params) {
    if (p === null || p === undefined) { buf[pos] = 0x05; pos += 1; }
    else if (typeof p === "number") { buf[pos] = 0x01; pos += 1; bufDv.setBigInt64(pos, BigInt(Math.trunc(p)), true); pos += 8; }
    else if (typeof p === "string") { buf[pos] = 0x03; pos += 1; const s = _encoder.encode(p); bufDv.setUint16(pos, s.length, false); pos += 2; buf.set(s, pos); pos += s.length; }
    else if (typeof p === "bigint") { buf[pos] = 0x01; pos += 1; bufDv.setBigInt64(pos, p, true); pos += 8; }
    else { buf[pos] = 0x05; pos += 1; }
  }
  return buildResult(requestId, 0x00, buf.subarray(0, pos));
}

// --- Handle ---

function dispatchHandle(requestId: number, args: Uint8Array): Uint8Array {
  const req = requests.get(requestId);
  if (!req) return buildResult(requestId, 0x01, new Uint8Array(0));

  if (args.length > 0) {
    try {
      const rowsDv = new DataView(args.buffer, args.byteOffset, args.byteLength);
      const { result } = readRowSet(rowsDv, 0);
      req.rows = result?.rows || [];
    } catch (e: any) { console.error(`[v2-shm] readRowSet error in handle:`, e.message); req.rows = []; }
  }

  const mod = modules[req.operation];
  const writes: Array<[string, ...any[]]> = [];
  const prefetchMode = req.prefetchMode;
  const prefetched: Record<string, any> = {};
  prefetched[req.prefetchKey] = prefetchMode === "query"
    ? (req.rows.length > 0 ? req.rows[0] : null) : req.rows;

  const ctx = {
    operation: req.operation, id: req.id, body: req.body,
    params: req.params, rows: req.rows, prefetched,
    write: (decl: [string, ...any[]]) => { writes.push(decl); },
  };

  let status = "ok";
  let sessionAction = 0;
  if (mod?.handle) {
    const r = mod.handle(ctx, { execute: (...a: any[]) => ctx.write(a as any) });
    if (typeof r === "string") status = r || "ok";
    else if (r && typeof r === "object") {
      status = (r as any).status || "ok";
      const sa = (r as any).sessionAction;
      if (sa === "set_authenticated") sessionAction = 1;
      else if (sa === "clear") sessionAction = 2;
    }
  }
  req.status = status;

  const statusBytes = _encoder.encode(status);
  const buf = new Uint8Array(FRAME_MAX);
  const bufDv = new DataView(buf.buffer);
  let pos = 0;
  bufDv.setUint16(pos, statusBytes.length, false); pos += 2;
  buf.set(statusBytes, pos); pos += statusBytes.length;
  buf[pos] = sessionAction; pos += 1;
  buf[pos] = writes.length; pos += 1;
  for (const w of writes) {
    const sqlB = _encoder.encode(String(w[0]));
    const wParams = w.slice(1);
    bufDv.setUint16(pos, sqlB.length, false); pos += 2;
    buf.set(sqlB, pos); pos += sqlB.length;
    buf[pos] = wParams.length; pos += 1;
    for (const p of wParams) {
      if (p === null || p === undefined) { buf[pos] = 0x05; pos += 1; }
      else if (typeof p === "number") { buf[pos] = 0x01; pos += 1; bufDv.setBigInt64(pos, BigInt(Math.trunc(p)), true); pos += 8; }
      else if (typeof p === "boolean") { buf[pos] = 0x01; pos += 1; bufDv.setBigInt64(pos, BigInt(p ? 1 : 0), true); pos += 8; }
      else if (typeof p === "string") { buf[pos] = 0x03; pos += 1; const s = _encoder.encode(String(p)); bufDv.setUint16(pos, s.length, false); pos += 2; buf.set(s, pos); pos += s.length; }
      else if (typeof p === "bigint") { buf[pos] = 0x01; pos += 1; bufDv.setBigInt64(pos, p, true); pos += 8; }
      else if (p instanceof Uint8Array) { buf[pos] = 0x04; pos += 1; bufDv.setUint16(pos, p.length, false); pos += 2; buf.set(p, pos); pos += p.length; }
      else { buf[pos] = 0x05; pos += 1; }
    }
  }
  return buildResult(requestId, 0x00, buf.subarray(0, pos));
}

// --- Render ---

function dispatchRender(requestId: number, _args: Uint8Array): Uint8Array {
  const req = requests.get(requestId);
  if (!req) return buildResult(requestId, 0x01, new Uint8Array(0));

  const mod = modules[req.operation];
  let html = "";
  if (mod?.render) {
    const prefetched: Record<string, any> = {};
    prefetched[req.prefetchKey] = req.prefetchMode === "query"
      ? (req.rows.length > 0 ? req.rows[0] : null) : req.rows;
    const ctx = {
      operation: req.operation, id: req.id, status: req.status,
      body: req.body, params: req.params, rows: req.rows,
      prefetched, is_sse: false,
    };
    html = mod.render(ctx) || "";
  }

  requests.delete(requestId);
  return buildResult(requestId, 0x00, _encoder.encode(html));
}

// --- Combined Route+Prefetch (2-RT, first half) ---
// Runs route() + prefetch() in one call. Returns route result +
// all SQL declarations. The server executes the SQL and sends
// rows back in the handle_render CALL (second half).

function dispatchRoutePrefetch(requestId: number, args: Uint8Array): Uint8Array {
  // Same args as dispatchRoute: [method:1][path_len:2 BE][path][body_len:2 BE][body]
  const dv = new DataView(args.buffer, args.byteOffset, args.byteLength);
  let pos = 0;
  const method = args[pos]; pos += 1;
  const pathLen = dv.getUint16(pos, false); pos += 2;
  const path = _decoder.decode(args.subarray(pos, pos + pathLen)); pos += pathLen;
  const bodyLen = dv.getUint16(pos, false); pos += 2;
  const body = _decoder.decode(args.subarray(pos, pos + bodyLen));

  // --- Route phase ---
  const methods = ["get", "put", "post", "delete"];
  const methodStr = methods[method] || "get";
  const queryIdx = path.indexOf("?");
  const queryString = queryIdx >= 0 ? path.slice(queryIdx + 1) : "";
  const queryParams = queryString ? new URLSearchParams(queryString) : null;

  let routeResult: any = null;
  let matchedOp = "";
  for (const entry of routeTable) {
    if (entry.method !== methodStr) continue;
    const params = matchRoute(path, entry.pattern);
    if (!params) continue;
    if (queryParams) {
      for (const qname of entry.query_params) {
        const qval = queryParams.get(qname);
        if (qval !== null) params[qname] = qval;
      }
    }
    const routeFn = modules[entry.operation]?.route;
    if (!routeFn) continue;
    const req = { method: methodStr, path, body, params };
    routeResult = routeFn(req);
    if (routeResult) { matchedOp = entry.operation; break; }
  }

  if (!routeResult) return buildResult(requestId, 0x01, new Uint8Array(0));

  // --- Prefetch phase (multi-capture) ---
  const mod = modules[matchedOp];
  interface CapturedQuery { sql: string; params: unknown[]; mode: "query" | "queryAll"; }
  const capturedQueries: CapturedQuery[] = [];
  const SENTINEL = Symbol("capture");

  const captureDb = {
    query: (sql: string, ...params: unknown[]) => {
      capturedQueries.push({ sql, params, mode: "query" });
      return SENTINEL;
    },
    queryAll: (sql: string, ...params: unknown[]) => {
      capturedQueries.push({ sql, params, mode: "queryAll" });
      return SENTINEL;
    },
  };

  // Extract return keys from handler source (same as dispatchPrefetch).
  const capturedKeys: string[] = [];
  const parsedBody = body.length > 0 ? JSON.parse(body) : {};
  const msg = {
    operation: matchedOp,
    id: (routeResult.id || "").replace(/-/g, ""),
    body: routeResult.body || parsedBody,
    ...(routeResult.params || {}),
  };

  let queryDecl: any = null;
  if (mod?.prefetch) {
    queryDecl = mod.prefetch(msg, captureDb);
  }

  // Extract key names from return value or source.
  if (queryDecl && typeof queryDecl === "object" && !(queryDecl instanceof Promise)) {
    for (const [k, v] of Object.entries(queryDecl)) {
      if (v === SENTINEL) capturedKeys.push(k);
    }
  } else if (queryDecl instanceof Promise && mod?.prefetch) {
    // Async handler — extract keys from source.
    const src = mod.prefetch.toString();
    const m = src.match(/return\s*(?:\{|\(\s*\{)\s*([^}]+)\}/);
    if (m) {
      for (const part of m[1].split(",")) {
        const key = part.split(":")[0].trim();
        if (key) capturedKeys.push(key);
      }
    }
  }

  // Store request state for the handle_render CALL.
  requests.set(requestId, {
    operation: matchedOp,
    id: msg.id,
    body: routeResult.body || parsedBody,
    params: routeResult.params || {},
    rows: [],
    status: "",
    prefetchKey: capturedKeys[0] || "rows",
    prefetchMode: capturedQueries[0]?.mode || "queryAll",
  });

  // Build result: [operation:1][id:16 LE][body_len:2 BE][body_json]
  //   [query_count:1][queries: [mode:1][sql_len:2 BE][sql][param_count:1][params...]]
  //   [key_count:1][keys: [key_len:1][key_bytes]...[mode:1]]
  const opValue = (OperationValues as any)[matchedOp];
  const idHex = (routeResult.id || "0".repeat(32)).replace(/-/g, "").padStart(32, "0");
  const bodyJson = _encoder.encode(JSON.stringify(routeResult.body || parsedBody));

  const buf = new Uint8Array(FRAME_MAX);
  const bufDv = new DataView(buf.buffer);
  let rpos = 0;

  // Operation + id
  buf[rpos] = opValue; rpos += 1;
  for (let i = 0; i < 16; i++) {
    buf[rpos + i] = parseInt(idHex.substr((15 - i) * 2, 2), 16);
  }
  rpos += 16;

  // Body JSON
  bufDv.setUint16(rpos, bodyJson.length, false); rpos += 2;
  buf.set(bodyJson, rpos); rpos += bodyJson.length;

  // Query declarations
  buf[rpos] = capturedQueries.length; rpos += 1;
  for (const q of capturedQueries) {
    buf[rpos] = q.mode === "query" ? 0x00 : 0x01; rpos += 1;
    const sqlBytes = _encoder.encode(q.sql);
    bufDv.setUint16(rpos, sqlBytes.length, false); rpos += 2;
    buf.set(sqlBytes, rpos); rpos += sqlBytes.length;
    buf[rpos] = q.params.length; rpos += 1;
    for (const p of q.params) {
      if (p === null || p === undefined) { buf[rpos] = 0x05; rpos += 1; }
      else if (typeof p === "number") { buf[rpos] = 0x01; rpos += 1; bufDv.setBigInt64(rpos, BigInt(Math.trunc(p)), true); rpos += 8; }
      else if (typeof p === "string") { buf[rpos] = 0x03; rpos += 1; const s = _encoder.encode(p); bufDv.setUint16(rpos, s.length, false); rpos += 2; buf.set(s, rpos); rpos += s.length; }
      else if (typeof p === "bigint") { buf[rpos] = 0x01; rpos += 1; bufDv.setBigInt64(rpos, p, true); rpos += 8; }
      else { buf[rpos] = 0x05; rpos += 1; }
    }
  }

  // Key names + modes
  buf[rpos] = capturedKeys.length; rpos += 1;
  for (let i = 0; i < capturedKeys.length; i++) {
    const keyBytes = _encoder.encode(capturedKeys[i]);
    buf[rpos] = keyBytes.length; rpos += 1;
    buf.set(keyBytes, rpos); rpos += keyBytes.length;
    buf[rpos] = (capturedQueries[i]?.mode === "query") ? 0x00 : 0x01; rpos += 1;
  }

  return buildResult(requestId, 0x00, buf.subarray(0, rpos));
}

// --- Combined Handle+Render (1-RT) ---

// Note: C-side pre-parsing of args was tested but N-API overhead for
// creating 4 extra JS values (napi_create_string_utf8 etc.) exceeded
function dispatchHandleRender(requestId: number, args: Uint8Array): Uint8Array {
  const dv = new DataView(args.buffer, args.byteOffset, args.byteLength);
  let pos = 0;

  // Parse: [operation:1][id:16 LE][body_len:2 BE][body][row_set_count:1][row_sets...]
  const opValue = args[pos]; pos += 1;
  const opName = reverseOpMap[opValue];
  if (!opName) {
    console.error(`[1rt] unknown opValue=${opValue} args.len=${args.length}`);
    return buildResult(requestId, 0x01, new Uint8Array(0));
  }

  // Decode id (16 bytes LE → hex string, no dashes).
  let id = "";
  for (let i = 15; i >= 0; i--) id += _hexTable[args[pos + i]];
  pos += 16;

  const bodyLen = dv.getUint16(pos, false); pos += 2;
  let body: any = {};
  if (bodyLen > 0) {
    const bodyStr = _decoder.decode(args.subarray(pos, pos + bodyLen));
    try {
      body = JSON.parse(bodyStr);
    } catch (e: any) {
      console.error(`[1rt] JSON parse fail: bodyLen=${bodyLen} str=${JSON.stringify(bodyStr.slice(0, 80))} pos=${pos} argsLen=${args.length}`);
      throw e;
    }
  }
  pos += bodyLen;

  const rowSetCount = args[pos]; pos += 1;

  // Deserialize row sets.
  const keyInfos = prefetchKeyMap[opName] || [];
  const prefetched: Record<string, any> = {};
  for (let i = 0; i < rowSetCount; i++) {
    try {
      const rsDv = new DataView(args.buffer, args.byteOffset + pos, args.byteLength - pos);
      const rsResult = readRowSet(rsDv, 0);
      const rows = rsResult.result?.rows || [];
      pos += rsResult.offset;

      if (i < keyInfos.length) {
        const info = keyInfos[i];
        prefetched[info.key] = info.mode === "query"
          ? (rows.length > 0 ? rows[0] : null) : rows;
      }
    } catch (e: any) {
      console.error(`[v2-shm] readRowSet error in handle_render:`, e.message);
      pos = args.byteLength;
    }
  }

  const mod = modules[opName];

  // Handle phase — reuse write array to reduce GC.
  _writes.length = 0;
  const ctx = _handleCtx;
  ctx.operation = opName; ctx.id = id; ctx.body = body;
  ctx.prefetched = prefetched; ctx.rows = _emptyRows;

  let status = "ok";
  let sessionAction = 0;
  if (mod?.handle) {
    const r = mod.handle(ctx, _writeDb);
    if (typeof r === "string") status = r || "ok";
    else if (r && typeof r === "object") {
      status = (r as any).status || "ok";
      const sa = (r as any).sessionAction;
      if (sa === "set_authenticated") sessionAction = 1;
      else if (sa === "clear") sessionAction = 2;
    }
  }

  // Render phase — reuse pre-allocated ctx.
  let html = "";
  if (mod?.render) {
    const rc = _renderCtx;
    rc.operation = opName; rc.id = id; rc.status = status;
    rc.body = body; rc.prefetched = prefetched;
    html = mod.render(rc) || "";
  }

  // Build RESULT directly into pre-allocated buffer.
  // Layout: [tag:1][request_id:4 BE][flag:1][status_len:2 BE][status][session:1][write_count:1][writes...][html]
  _resultBuf[0] = 0x11;
  _resultDv.setUint32(1, requestId, false);
  _resultBuf[5] = 0x00; // success flag
  let rpos = 6; // after RESULT header

  const statusBytes = _encoder.encode(status);
  _resultDv.setUint16(rpos, statusBytes.length, false); rpos += 2;
  _resultBuf.set(statusBytes, rpos); rpos += statusBytes.length;
  _resultBuf[rpos] = sessionAction; rpos += 1;
  _resultBuf[rpos] = _writes.length; rpos += 1;
  for (const w of _writes) {
    const sqlB = _encoder.encode(String(w[0]));
    const wParams = w.slice(1);
    _resultDv.setUint16(rpos, sqlB.length, false); rpos += 2;
    _resultBuf.set(sqlB, rpos); rpos += sqlB.length;
    _resultBuf[rpos] = wParams.length; rpos += 1;
    for (const p of wParams) {
      if (p === null || p === undefined) { _resultBuf[rpos] = 0x05; rpos += 1; }
      else if (typeof p === "number") { _resultBuf[rpos] = 0x01; rpos += 1; _resultDv.setBigInt64(rpos, BigInt(Math.trunc(p)), true); rpos += 8; }
      else if (typeof p === "boolean") { _resultBuf[rpos] = 0x01; rpos += 1; _resultDv.setBigInt64(rpos, BigInt(p ? 1 : 0), true); rpos += 8; }
      else if (typeof p === "string") { _resultBuf[rpos] = 0x03; rpos += 1; const s = _encoder.encode(String(p)); _resultDv.setUint16(rpos, s.length, false); rpos += 2; _resultBuf.set(s, rpos); rpos += s.length; }
      else if (typeof p === "bigint") { _resultBuf[rpos] = 0x01; rpos += 1; _resultDv.setBigInt64(rpos, p, true); rpos += 8; }
      else if (p instanceof Uint8Array) { _resultBuf[rpos] = 0x04; rpos += 1; _resultDv.setUint16(rpos, p.length, false); rpos += 2; _resultBuf.set(p, rpos); rpos += p.length; }
      else { _resultBuf[rpos] = 0x05; rpos += 1; }
    }
  }
  // HTML directly into result buffer — no intermediate encode + copy.
  const htmlLen = _encoder.encodeInto(html, _resultBuf.subarray(rpos)).written ?? 0;
  rpos += htmlLen;

  return _resultBuf.subarray(0, rpos);
}
