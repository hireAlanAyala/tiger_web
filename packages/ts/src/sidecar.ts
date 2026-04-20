// SHM sidecar runtime — 1-RT and 2-RT dispatch over shared memory.
//
// 1-RT: server routes + executes prefetch SQL natively,
// sends one handle_render CALL. Sidecar runs handle + render.
// 2-RT: server sends route_prefetch CALL, sidecar declares
// SQL, server executes, then sends handle_render CALL.
//
// Uses mmap + setImmediate polling. C addon (pollDispatch) handles
// SHM I/O, CRC, frame header parsing. JS only runs handler logic.
//
// Library function — called by bin/focus-sidecar.ts with injected registry.
//
// DETERMINISM LIMITATION: This sidecar runs on V8 with setImmediate
// polling. V8's event loop timing, GC pauses, and native addon blocking
// are non-deterministic and cannot be seeded. Timing-dependent bugs
// (race conditions, GC during RESULT write, event loop starvation) are
// unreproducible. The Zig server's SimSidecar provides deterministic
// coverage of the protocol state machine. This TS runtime is tested
// via integration tests (end-to-end) and fuzz tests (parser boundary).
// Accepted trade-off for TypeScript language support.

import net from "node:net";
import { crc32 } from "node:zlib";
import { createRequire } from "node:module";
import { ShmClient } from "./shm_client.ts";
import { matchRoute } from "./routing.ts";
import { readRowSet } from "./serde.ts";

// Native addon must use require (Node.js doesn't support import for .node files).
const require_ = createRequire(import.meta.url);
const shmAddon = require_("../native/shm.node");

/** Registry of generated handler modules — injected by the bin entry point. */
export interface SidecarRegistry {
  modules: Record<string, any>;
  routeTable: Array<{ method: string; pattern: string; operation: string; query_params: string[] }>;
  prefetchKeyMap: Record<string, Array<{ key: string; mode: "query" | "queryAll" }>>;
  OperationValues: Record<string, number>;
  workerFunctions?: Record<string, { fn: (...args: any[]) => Promise<any>; returns: string }>;
}

/** Start the sidecar. Connects to SHM, sends READY, starts polling. */
export function createSidecar(shmName: string, socketPath: string, registry: SidecarRegistry): void {

const { modules, routeTable, prefetchKeyMap, OperationValues } = registry;

const _decoder = new TextDecoder();
const _encoder = new TextEncoder();

const FRAME_MAX = 256 * 1024;

// Pre-allocated CRC length buffer — reused by writeWorkerResult.
const _crcLenBuf = Buffer.alloc(4);

// Pre-computed hex lookup — avoids toString(16) + padStart per byte.
const _hexTable: string[] = new Array(256);
for (let i = 0; i < 256; i++) _hexTable[i] = i.toString(16).padStart(2, "0");

// Bounded writes — matches server's writes_max (21).
// If a handler exceeds this, it's a bug — fail fast, don't overflow the RESULT frame.
const WRITES_MAX = 21;

// Pre-allocated objects for handle_render hot path — reduces GC pressure.
const _writes: Array<[string, ...any[]]> = [];
const _emptyRows: any[] = [];
const _emptyParams: Record<string, string> = {};
const _handleCtx: any = {
  operation: "", id: "", body: {}, params: _emptyParams,
  rows: _emptyRows, prefetched: {},
  write: (decl: [string, ...any[]]) => { _writes.push(decl); },
};
const _writeDb = {
  execute: (...a: any[]) => {
    if (_writes.length >= WRITES_MAX) {
      throw new Error(
        `writes_max exceeded (${WRITES_MAX}) in handler '${_handleCtx.operation}'. ` +
        `Split into a worker or batch your writes.`
      );
    }
    _writes.push(a as any);
  }
};
const _workerDispatches: Array<{name: string, args: any[]}> = [];

// Worker proxy — handlers call worker.charge_payment(id, { amount }) etc.
// The first arg is the entity id. The second (optional) is the body object.
// These are serialized into the RESULT dispatch section as type-tagged values.
const worker: Record<string, (id: string, body?: any) => void> = new Proxy({} as any, {
  get(_target: any, prop: string) {
    return (id: string, body?: any) => {
      _workerDispatches.push({ name: prop, args: [id, body ?? {}] });
    };
  }
});

const _renderCtx: any = {
  operation: "", id: "", status: "", body: {}, params: _emptyParams,
  rows: _emptyRows, prefetched: {}, is_sse: false,
};

// Reverse map: operation int value → operation name.
const reverseOpMap: Record<number, string> = {};
for (const [name, val] of Object.entries(OperationValues)) {
  reverseOpMap[val as number] = name;
}

// Prefetch key map imported from generated code — extracted at build time
// by adapters/typescript.ts. No runtime fn.toString() parsing.

// --- SHM setup ---
// Read slot_count and frame_max from the SHM region header.
// No hardcoded constants — the server writes these at init.
const client = ShmClient.open(shmName);

console.log(`[shm] connected to ${shmName}`);

// --- Control channel (Unix socket) ---
// The server requires a READY handshake on the Unix socket before
// dispatching requests. SHM is the data channel; the socket is the
// control channel (liveness detection, version negotiation).
if (socketPath) {
  const sock = net.createConnection(socketPath, () => {
    // READY frame: [tag=0x20][version: u16 BE]
    const PROTOCOL_VERSION = 1;
    const payload = Buffer.alloc(3);
    payload[0] = 0x20; // CallTag.ready
    payload.writeUInt16BE(PROTOCOL_VERSION, 1);

    // Wire frame: [len: u32 BE][crc32: u32 LE][payload]
    const frame = Buffer.alloc(8 + payload.length);
    frame.writeUInt32BE(payload.length, 0);
    const lenBuf = Buffer.alloc(4);
    lenBuf.writeUInt32BE(payload.length);
    const crc = crc32(Buffer.concat([lenBuf, payload]));
    frame.writeUInt32LE(crc, 4);
    payload.copy(frame, 8);

    sock.write(frame);
    console.log(`[shm] READY sent to ${socketPath}`);
  });
  sock.on("error", (e: any) => {
    console.error(`[shm] control socket error: ${e.message}`);
    process.exit(1);
  });
  // Keep socket alive — disconnect = server kills our requests.
}

// --- Frame dispatch ---
// C addon pre-parses CALL frames: tag, request_id, function name → funcIndex.
// JS only runs handler logic. C writes RESULT back to SHM.
// funcIndex: 4=handle_render (1-RT), 5=route_prefetch (2-RT first half)

client.setDispatchHandler((_slotIndex: number, funcIndex: number, requestId: number, args: Buffer): Uint8Array => {
  try {
    switch (funcIndex) {
      case 4: return dispatchHandleRender(requestId, args);
      case 5: return dispatchRoutePrefetch(requestId, args);
      default: return buildResult(requestId, 0x01, new Uint8Array(0));
    }
  } catch (e: any) {
    console.error(`[shm] func ${funcIndex} error:`, e.message, e.stack?.split('\n')[1] || '');
    return buildResult(requestId, 0x01, new Uint8Array(0));
  }
});

// Start polling. setImmediate gives higher throughput than futex
// under load (~15K vs ~8K) because V8 JIT stays hot between ticks.
// Futex is better for idle CPU (0% vs 100%) — use startWaiting()
// when idle efficiency matters more than peak throughput.
client.startPolling();
console.log("[shm] polling started");

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

// --- Route+Prefetch (2-RT, first half) ---
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

// Handler timeout warning: if handle+render exceeds this, log a warning.
// Not a hard kill (can't abort synchronous JS), but alerts the developer.
const HANDLER_WARN_MS = 100;

function dispatchHandleRender(requestId: number, args: Uint8Array): Uint8Array {
  const startTime = performance.now();
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
  // Row set deserialization follows.

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
      console.error(`[shm] readRowSet error in handle_render:`, e.message);
      pos = args.byteLength;
    }
  }

  const mod = modules[opName];

  // Handle phase — reuse write array and dispatch list.
  _writes.length = 0;
  _workerDispatches.length = 0;
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
  // Layout: [tag:1][request_id:4 BE][flag:1][status_len:2 BE][status][session:1][write_count:1][writes...][dispatch_count:1][dispatches...][html]
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
  // Dispatch section: [dispatch_count:1][dispatches...]
  // Each dispatch: [name_len:1][name][args_len:2 BE][args]
  // Args are serialized as type-tagged values (same as write params).
  _resultBuf[rpos] = _workerDispatches.length; rpos += 1;
  for (const d of _workerDispatches) {
    const nameBytes = _encoder.encode(d.name);
    _resultBuf[rpos] = nameBytes.length; rpos += 1;
    _resultBuf.set(nameBytes, rpos); rpos += nameBytes.length;
    // Serialize args as type-tagged params.
    const argsStart = rpos;
    rpos += 2; // reserve space for args_len
    for (const a of d.args) {
      if (a === null || a === undefined) { _resultBuf[rpos] = 0x05; rpos += 1; }
      else if (typeof a === "number") { _resultBuf[rpos] = 0x01; rpos += 1; _resultDv.setBigInt64(rpos, BigInt(Math.trunc(a)), true); rpos += 8; }
      else if (typeof a === "string") { _resultBuf[rpos] = 0x03; rpos += 1; const s = _encoder.encode(a); _resultDv.setUint16(rpos, s.length, false); rpos += 2; _resultBuf.set(s, rpos); rpos += s.length; }
      else if (typeof a === "bigint") { _resultBuf[rpos] = 0x01; rpos += 1; _resultDv.setBigInt64(rpos, a, true); rpos += 8; }
      else { _resultBuf[rpos] = 0x05; rpos += 1; }
    }
    const argsLen = rpos - argsStart - 2;
    _resultDv.setUint16(argsStart, argsLen, false);
  }
  // HTML directly into result buffer — no intermediate encode + copy.
  const htmlLen = _encoder.encodeInto(html, _resultBuf.subarray(rpos)).written ?? 0;
  rpos += htmlLen;

  // Post-dispatch invariants — catch state leaks between requests.
  if (rpos > FRAME_MAX) throw new Error(`RESULT frame overflow: ${rpos} > ${FRAME_MAX}`);

  // Handler timing warning — alerts developer to slow handlers that
  // could cause server-side timeouts and abandoned slots.
  const elapsed = performance.now() - startTime;
  if (elapsed > HANDLER_WARN_MS) {
    console.warn(`[shm] slow handler: ${opName} took ${elapsed.toFixed(1)}ms (warn threshold: ${HANDLER_WARN_MS}ms)`);
  }

  return _resultBuf.subarray(0, rpos);
}

// =====================================================================
// Worker SHM client — async CALL handling over second SHM region.
//
// Polls the worker SHM region (`{shmName}-workers`) for CALL frames.
// Each CALL starts an async worker function. When the Promise resolves,
// the RESULT is written back to the SHM slot.
//
// JS-level polling (not C addon) — worker names are dynamic.
// =====================================================================

// shmAddon and crc32 imported at module level above.
let workerFns: Record<string, { fn: (...args: any[]) => Promise<any>; returns: string }> | null = null;
if (registry.workerFunctions && Object.keys(registry.workerFunctions).length > 0) {
  workerFns = registry.workerFunctions;
}

if (workerFns && Object.keys(workerFns).length > 0) {
  const workerShmName = shmName + "-workers";
  // Read slot_count and frame_max from the worker SHM region header.
  const WORKER_REGION_HEADER_SIZE = 64;

  let workerBuf: Buffer;
  let workerSlotCount = 0;
  let workerFrameMax = 0;
  try {
    const shmPath = "/" + workerShmName;
    const headerBuf: Buffer = shmAddon.mmapShm(shmPath, WORKER_REGION_HEADER_SIZE);
    workerSlotCount = headerBuf.readUInt16LE(4);
    workerFrameMax = headerBuf.readUInt32LE(8);
    const regionSize = 64 + workerSlotCount * (64 + workerFrameMax * 2);
    workerBuf = shmAddon.mmapShm(shmPath, regionSize);
    console.log(`[shm] worker transport: ${workerShmName} (${workerSlotCount} slots, frame_max=${workerFrameMax})`);
  } catch (e: any) {
    console.error(`[shm] worker SHM not available: ${e.message}`);
    workerFns = null;
    workerBuf = Buffer.alloc(0);
  }

  if (workerFns) {
    const WHDR = 64; // region header.
    const WSLOT_HDR = 64; // slot header.
    const WSLOT_PAIR = WSLOT_HDR + workerFrameMax * 2;
    const wLastSeqs = new Uint32Array(workerSlotCount);
    const wResultBuf = new Uint8Array(FRAME_MAX);
    const wResultDv = new DataView(wResultBuf.buffer);
    const wFns = workerFns; // capture for closure

    function pollWorkerShm() {
      for (let i = 0; i < workerSlotCount; i++) {
        const hdr = WHDR + i * WSLOT_PAIR;
        const serverSeq = workerBuf.readUInt32LE(hdr); // server_seq
        if (serverSeq <= wLastSeqs[i]) continue;
        wLastSeqs[i] = serverSeq;

        // Read request.
        const reqLen = workerBuf.readUInt32LE(hdr + 8); // request_len
        if (reqLen === 0 || reqLen > FRAME_MAX) continue;
        const reqOffset = hdr + WSLOT_HDR;
        const reqData = workerBuf.subarray(reqOffset, reqOffset + reqLen);

        // Parse CALL: [tag:1][request_id:4 BE][name_len:2 BE][name][args]
        if (reqData.length < 7) continue;
        if (reqData[0] !== 0x10) continue; // not a CALL tag
        const requestId = reqData.readUInt32BE(1);
        const nameLen = reqData.readUInt16BE(5);
        if (7 + nameLen > reqData.length) continue;
        const name = _decoder.decode(reqData.subarray(7, 7 + nameLen));
        const argsRaw = reqData.subarray(7 + nameLen);

        // Look up worker function.
        const wf = wFns[name];
        if (!wf) {
          console.error(`[shm] unknown worker: ${name}`);
          writeWorkerResult(workerBuf, i, WHDR, WSLOT_PAIR, workerFrameMax, requestId, 0x01, new Uint8Array(0));
          continue;
        }

        // Build ctx and db for the worker function.
        // ctx = { id, body } — id from first arg, body from second.
        const args = deserializeArgs(argsRaw);
        const workerCtx = { id: args[0] ?? "", body: args[1] ?? {} };

        // db provides query/queryAll over the QUERY sub-protocol.
        // Each call writes a QUERY frame to the slot's response area
        // and polls for the server's QUERY_RESULT in the request area.
        const slot = i;
        const rid = requestId;
        let queryCounter = 0;
        const workerDb = {
          query: (sql: string, ...params: any[]) => workerQuery(workerBuf, slot, WHDR, WSLOT_PAIR, workerFrameMax, rid, queryCounter++, sql, params, "query"),
          queryAll: (sql: string, ...params: any[]) => workerQuery(workerBuf, slot, WHDR, WSLOT_PAIR, workerFrameMax, rid, queryCounter++, sql, params, "queryAll"),
        };

        // Run async worker function with (ctx, db).
        (async () => {
          try {
            const result = await wf.fn(workerCtx, workerDb);
            const resultJson = _encoder.encode(JSON.stringify(result ?? {}));
            writeWorkerResult(workerBuf, slot, WHDR, WSLOT_PAIR, workerFrameMax, rid, 0x00, resultJson);
          } catch (e: any) {
            console.error(`[shm] worker ${name} error:`, e.message);
            const errMsg = _encoder.encode(e.message || "worker error");
            writeWorkerResult(workerBuf, slot, WHDR, WSLOT_PAIR, workerFrameMax, rid, 0x01, errMsg);
          }
        })();
      }
      setImmediate(pollWorkerShm);
    }

    setImmediate(pollWorkerShm);
    console.log(`[shm] worker polling started (${Object.keys(wFns).length} workers)`);
  }
}

/// Write RESULT to worker SHM slot. Must follow the same write ordering
/// as the C addon's pollDispatch: data → len → CRC → state → seq.
/// INVARIANT: CRC is computed OVER the final data. If this function is
/// interrupted (process killed), either CRC mismatches (partial write
/// detected) or sidecar_seq isn't bumped (server never reads it). Safe.
function writeWorkerResult(buf: Buffer, slot: number, regionHdr: number, slotPairSize: number,
  frameMax: number, requestId: number, flag: number, data: Uint8Array) {
  const hdr = regionHdr + slot * slotPairSize;
  const respOffset = hdr + 64 + frameMax; // slot header + request area.

  // Step 1: Write RESULT payload to response area.
  let pos = 0;
  buf[respOffset + pos] = 0x11; pos += 1;
  buf.writeUInt32BE(requestId, respOffset + pos); pos += 4;
  buf[respOffset + pos] = flag; pos += 1;
  if (data.length > 0) {
    buf.set(data, respOffset + pos);
    pos += data.length;
  }

  // Step 2: Set response_len.
  buf.writeUInt32LE(pos, hdr + 12);

  // Step 3: Compute and write CRC (over len_bytes ++ payload_bytes).
  // Pre-allocated 4-byte buffer for len — avoids allocation per call.
  // TODO: expose C addon's compute_crc via N-API for zero-allocation CRC.
  _crcLenBuf.writeUInt32LE(pos);
  const crcVal = crc32(Buffer.concat([_crcLenBuf, buf.subarray(respOffset, respOffset + pos)]));
  buf.writeUInt32LE(crcVal, hdr + 20); // response_crc

  // Step 4: Set slot_state = result_written.
  buf[hdr + 24] = 2; // SlotState.result_written

  // Step 5: Bump sidecar_seq (must be LAST — server reads this to detect response).
  const curSeq = buf.readUInt32LE(hdr + 4);
  buf.writeUInt32LE(curSeq + 1, hdr + 4);
  // No futex_wake: server polls sidecar_seq in tick loop.
}

/// Send a QUERY frame over the worker SHM and poll for QUERY_RESULT.
/// Returns a Promise that resolves with the first result row (query mode)
/// or all rows (queryAll mode).
async function workerQuery(
  buf: Buffer, slot: number, regionHdr: number, slotPairSize: number,
  frameMax: number, requestId: number, queryId: number,
  sql: string, params: any[], mode: "query" | "queryAll"
): Promise<any> {
  const hdr = regionHdr + slot * slotPairSize;
  const respOffset = hdr + 64 + frameMax; // response area.

  // Build QUERY frame: [tag:0x12][request_id:4 BE][query_id:2 BE][sql_len:2 BE][sql][mode:1][param_count:1][params...]
  let pos = 0;
  buf[respOffset + pos] = 0x12; pos += 1;
  buf.writeUInt32BE(requestId, respOffset + pos); pos += 4;
  buf.writeUInt16BE(queryId, respOffset + pos); pos += 2;
  const sqlBytes = _encoder.encode(sql);
  buf.writeUInt16BE(sqlBytes.length, respOffset + pos); pos += 2;
  buf.set(sqlBytes, respOffset + pos); pos += sqlBytes.length;
  buf[respOffset + pos] = mode === "queryAll" ? 0x01 : 0x00; pos += 1;
  buf[respOffset + pos] = params.length; pos += 1;
  for (const p of params) {
    if (p === null || p === undefined) { buf[respOffset + pos] = 0x05; pos += 1; }
    else if (typeof p === "number") { buf[respOffset + pos] = 0x01; pos += 1; buf.writeBigInt64LE(BigInt(Math.trunc(p)), respOffset + pos); pos += 8; }
    else if (typeof p === "string") { buf[respOffset + pos] = 0x03; pos += 1; const s = _encoder.encode(p); buf.writeUInt16BE(s.length, respOffset + pos); pos += 2; buf.set(s, respOffset + pos); pos += s.length; }
    else { buf[respOffset + pos] = 0x05; pos += 1; }
  }

  // Set response_len + CRC + bump sidecar_seq.
  const queryLen = pos;
  buf.writeUInt32LE(queryLen, hdr + 12); // response_len.
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32LE(queryLen);
  // crc32 imported at module level from node:zlib.
  const crcVal = crc32(Buffer.concat([lenBuf, buf.subarray(respOffset, respOffset + queryLen)]));
  buf.writeUInt32LE(crcVal, hdr + 20); // response_crc.
  const curSeq = buf.readUInt32LE(hdr + 4);
  buf.writeUInt32LE(curSeq + 1, hdr + 4);
  // No futex_wake: server polls sidecar_seq in tick loop.

  // Poll for QUERY_RESULT in the request area.
  const reqOffset = hdr + 64; // request area starts after slot header.
  const expectedServerSeq = buf.readUInt32LE(hdr) + 1; // server will bump server_seq.
  return new Promise<any>((resolve) => {
    const poll = () => {
      const serverSeq = buf.readUInt32LE(hdr); // server_seq.
      if (serverSeq < expectedServerSeq) {
        setImmediate(poll);
        return;
      }
      // Read QUERY_RESULT: [tag:0x13][request_id:4 BE][query_id:2 BE][row_set...]
      const reqLen = buf.readUInt32LE(hdr + 8); // request_len.
      if (reqLen < 7) { resolve(mode === "queryAll" ? [] : null); return; }
      const rowSetData = buf.subarray(reqOffset + 7, reqOffset + reqLen);
      // Parse row set using the same readRowSet as prefetch.
      try {
        // readRowSet imported at top of file (from ./serde.ts).
        const dv = new DataView(rowSetData.buffer, rowSetData.byteOffset, rowSetData.byteLength);
        const rsResult = readRowSet(dv, 0);
        const rows = rsResult.result?.rows || [];
        resolve(mode === "queryAll" ? rows : (rows.length > 0 ? rows[0] : null));
      } catch {
        resolve(mode === "queryAll" ? [] : null);
      }
    };
    setImmediate(poll);
  });
}

function deserializeArgs(data: Uint8Array): any[] {
  const args: any[] = [];
  let pos = 0;
  while (pos < data.length) {
    const tag = data[pos]; pos += 1;
    switch (tag) {
      case 0x01: { // integer
        const dv = new DataView(data.buffer, data.byteOffset + pos, 8);
        args.push(Number(dv.getBigInt64(0, true)));
        pos += 8;
        break;
      }
      case 0x02: { // float
        const dv = new DataView(data.buffer, data.byteOffset + pos, 8);
        args.push(dv.getFloat64(0, true));
        pos += 8;
        break;
      }
      case 0x03: { // text
        const len = new DataView(data.buffer, data.byteOffset + pos, 2).getUint16(0, false);
        pos += 2;
        args.push(_decoder.decode(data.subarray(pos, pos + len)));
        pos += len;
        break;
      }
      case 0x04: { // blob
        const len = new DataView(data.buffer, data.byteOffset + pos, 2).getUint16(0, false);
        pos += 2;
        args.push(data.slice(pos, pos + len));
        pos += len;
        break;
      }
      case 0x05: // null
        args.push(null);
        break;
      default:
        return args; // unknown tag — stop
    }
  }
  return args;
}

} // end createSidecar
