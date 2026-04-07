// Sidecar runtime v2 + shared memory transport.
//
// Same dispatch logic as call_runtime_v2.ts but uses shared memory
// (mmap + futex) instead of unix socket. The ShmClient polls for
// requests, dispatches to handler functions, writes responses back.
//
// Usage: npx tsx adapters/call_runtime_v2_shm.ts <shm-name>

import { ShmClient } from "./shm_client.ts";
import { modules, routeTable } from "../generated/handlers.generated.ts";
import { OperationValues } from "../generated/types.generated.ts";
import { matchRoute } from "../generated/routing.ts";
import { readRowSet } from "../generated/serde.ts";

const _decoder = new TextDecoder();
const _encoder = new TextEncoder();

const FRAME_MAX = 256 * 1024;

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
      default: return buildResult(requestId, 0x01, new Uint8Array(0));
    }
  } catch (e: any) {
    console.error(`[v2-shm] func ${funcIndex} error:`, e.message);
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

function buildResult(requestId: number, flag: number, data: Uint8Array): Uint8Array {
  const len = 1 + 4 + 1 + data.length;
  const buf = new Uint8Array(len);
  const dv = new DataView(buf.buffer);
  buf[0] = 0x11; // RESULT tag
  dv.setUint32(1, requestId, false);
  buf[5] = flag;
  if (data.length > 0) buf.set(data, 6);
  return buf;
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
    } catch { req.rows = []; }
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
