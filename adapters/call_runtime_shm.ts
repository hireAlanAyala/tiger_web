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
// Usage: npx tsx adapters/call_runtime_shm.ts <shm-name> [slot-count]

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
const _workerDispatches: Array<{name: string, args: any[]}> = [];

// Worker proxy — handlers call worker.charge_payment(id, amount) etc.
// Each call appends to _workerDispatches, serialized into the RESULT dispatch section.
export const worker: Record<string, (...args: any[]) => void> = new Proxy({} as any, {
  get(_target: any, prop: string) {
    return (...args: any[]) => {
      _workerDispatches.push({ name: prop, args });
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
  console.error("Usage: npx tsx adapters/call_runtime_shm.ts <shm-name> [slot-count]");
  process.exit(1);
}
const client = new ShmClient({
  shmName,
  slotCount,
  slotDataSize: FRAME_MAX,
});

console.log(`[shm] connected to ${shmName}`);

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

const shmAddon = require("../addons/shm/shm.node");
const _zlib = require("zlib");
let workerFns: Record<string, { fn: (...args: any[]) => Promise<any>; returns: string }> | null = null;
try {
  const gen = require("../generated/handlers.generated.ts");
  if (gen.workerFunctions) workerFns = gen.workerFunctions;
} catch { /* no workers defined */ }

if (workerFns && Object.keys(workerFns).length > 0) {
  const workerShmName = shmName + "-workers";
  const workerSlotCount = 16; // Must match constants.max_in_flight_workers.

  let workerBuf: Buffer;
  try {
    const shmPath = "/" + workerShmName;
    const regionSize = 64 + workerSlotCount * (64 + FRAME_MAX * 2);
    workerBuf = shmAddon.mmapShm(shmPath, regionSize);
    console.log(`[shm] worker transport: ${workerShmName} (${workerSlotCount} slots)`);
  } catch (e: any) {
    console.error(`[shm] worker SHM not available: ${e.message}`);
    workerFns = null;
    workerBuf = Buffer.alloc(0);
  }

  if (workerFns) {
    const WHDR = 64; // region header
    const WSLOT_HDR = 64; // slot header
    const WSLOT_PAIR = WSLOT_HDR + FRAME_MAX * 2;
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
          writeWorkerResult(workerBuf, i, WHDR, WSLOT_PAIR, requestId, 0x01, new Uint8Array(0));
          continue;
        }

        // Run async worker function. Fire and forget — result written when done.
        const slot = i;
        const rid = requestId;
        (async () => {
          try {
            // Deserialize args from type-tagged format.
            const args = deserializeArgs(argsRaw);
            const result = await wf.fn(...args);
            // Serialize result as JSON text.
            const resultJson = _encoder.encode(JSON.stringify(result ?? {}));
            writeWorkerResult(workerBuf, slot, WHDR, WSLOT_PAIR, rid, 0x00, resultJson);
          } catch (e: any) {
            console.error(`[shm] worker ${name} error:`, e.message);
            const errMsg = _encoder.encode(e.message || "worker error");
            writeWorkerResult(workerBuf, slot, WHDR, WSLOT_PAIR, rid, 0x01, errMsg);
          }
        })();
      }
      setImmediate(pollWorkerShm);
    }

    setImmediate(pollWorkerShm);
    console.log(`[shm] worker polling started (${Object.keys(wFns).length} workers)`);
  }
}

function writeWorkerResult(buf: Buffer, slot: number, regionHdr: number, slotPairSize: number,
  requestId: number, flag: number, data: Uint8Array) {
  const hdr = regionHdr + slot * slotPairSize;
  const respOffset = hdr + 64 + FRAME_MAX; // slot header + request area

  // Build RESULT: [tag:0x11][request_id:4 BE][flag:1][data]
  let pos = 0;
  buf[respOffset + pos] = 0x11; pos += 1;
  buf.writeUInt32BE(requestId, respOffset + pos); pos += 4;
  buf[respOffset + pos] = flag; pos += 1;
  if (data.length > 0) {
    buf.set(data, respOffset + pos);
    pos += data.length;
  }

  // Set response_len.
  buf.writeUInt32LE(pos, hdr + 12);

  // CRC: len_bytes ++ payload_bytes (matches Zig convention).
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32LE(pos);
  // Simple CRC32 using Node.js zlib.
  const { crc32 } = _zlib;
  const crcVal = crc32(Buffer.concat([lenBuf, buf.subarray(respOffset, respOffset + pos)]));
  buf.writeUInt32LE(crcVal, hdr + 20); // response_crc

  // Bump sidecar_seq + futex wake.
  const curSeq = buf.readUInt32LE(hdr + 4);
  buf.writeUInt32LE(curSeq + 1, hdr + 4);
  shmAddon.futexWake(buf, hdr + 4);
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
