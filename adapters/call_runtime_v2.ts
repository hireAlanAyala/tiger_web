// Sidecar runtime v2 — pipelined stateless protocol.
//
// 4 RTs per request: route, prefetch, handle, render.
// Every RT is synchronous. No await. No db object. The framework
// holds all state between RTs. Per-request state isolated via Map.
//
// Pipelining: the framework interleaves RTs from different requests.
// The runtime processes them sequentially (Node event loop) but
// different requests can be in different stages simultaneously.
//
// Usage: npx tsx adapters/call_runtime_v2.ts <socket-path>

import * as net from "net";
import { crc32 } from "node:zlib";

// --- Protocol constants (match protocol.zig) ---

const CallTag = {
  call: 0x10,
  result: 0x11,
  ready: 0x20,
} as const;

const ResultFlag = {
  success: 0x00,
  failure: 0x01,
} as const;

const FRAME_HEADER_SIZE = 8;
const FRAME_MAX = 256 * 1024;
const PROTOCOL_VERSION = 2;

// --- Handler registry ---

import { modules, routeTable } from "../generated/handlers.generated.ts";
import { OperationValues } from "../generated/types.generated.ts";
import { matchRoute } from "../generated/routing.ts";

// --- Pre-allocated buffers ---

const _decoder = new TextDecoder();
const _encoder = new TextEncoder();
const _frameHeader = Buffer.alloc(FRAME_HEADER_SIZE);

// --- Per-request state (Map keyed by request_id) ---

interface RequestState {
  operation: string;
  id: string;
  body: any;
  params: Record<string, string>;
  rows: any[];
  status: string;
}

const requests = new Map<number, RequestState>();

// --- Frame IO ---

function sendFrame(conn: net.Socket, payload: Uint8Array): void {
  _frameHeader.writeUInt32BE(payload.length, 0);
  const crcLen = crc32(_frameHeader.subarray(0, 4));
  const crcFull = payload.length > 0
    ? crc32(Buffer.from(payload), crcLen)
    : crcLen;
  _frameHeader.writeUInt32LE(crcFull, 4);
  conn.write(_frameHeader);
  if (payload.length > 0) conn.write(Buffer.from(payload));
}

function buildResult(requestId: number, flag: number, data: Uint8Array): Uint8Array {
  const len = 1 + 4 + 1 + data.length;
  const buf = new Uint8Array(len);
  const dv = new DataView(buf.buffer);
  buf[0] = CallTag.result;
  dv.setUint32(1, requestId, false);
  buf[5] = flag;
  if (data.length > 0) buf.set(data, 6);
  return buf;
}

// --- Socket setup ---

const socketPath = process.argv[2];
if (!socketPath) {
  console.error("Usage: npx tsx adapters/call_runtime_v2.ts <socket-path>");
  process.exit(1);
}

let pendingBuf = Buffer.alloc(FRAME_MAX + FRAME_HEADER_SIZE);
let pendingLen = 0;

const conn = net.createConnection(socketPath, () => {
  const readyPayload = new Uint8Array(3);
  readyPayload[0] = 0x20;
  const readyDv = new DataView(readyPayload.buffer);
  readyDv.setUint16(1, PROTOCOL_VERSION, false);
  sendFrame(conn, readyPayload);
  console.log(`[v2] connected, READY version=${PROTOCOL_VERSION}`);
});

conn.on("data", (chunk: Buffer) => {
  if (pendingLen + chunk.length > pendingBuf.length) {
    const newBuf = Buffer.alloc(Math.max(pendingBuf.length * 2, pendingLen + chunk.length));
    pendingBuf.copy(newBuf, 0, 0, pendingLen);
    pendingBuf = newBuf;
  }
  chunk.copy(pendingBuf, pendingLen);
  pendingLen += chunk.length;
  processFrames();
});

conn.on("error", (err: any) => {
  console.error("[v2] error:", err.message);
  process.exit(1);
});

conn.on("close", () => {
  console.log("[v2] disconnected");
  process.exit(0);
});

// --- Frame processing ---

function processFrames(): void {
  while (pendingLen >= FRAME_HEADER_SIZE) {
    const frameLen = pendingBuf.readUInt32BE(0);
    if (frameLen > FRAME_MAX) {
      console.error("[v2] frame too large:", frameLen);
      conn.destroy();
      return;
    }
    const totalLen = FRAME_HEADER_SIZE + frameLen;
    if (pendingLen < totalLen) break;

    const storedCrc = pendingBuf.readUInt32LE(4);
    const crcLen = crc32(pendingBuf.subarray(0, 4));
    const computedCrc = frameLen > 0
      ? crc32(pendingBuf.subarray(FRAME_HEADER_SIZE, totalLen), crcLen)
      : crcLen;
    if ((computedCrc >>> 0) !== (storedCrc >>> 0)) {
      console.error("[v2] CRC mismatch");
      conn.destroy();
      return;
    }

    const frame = new Uint8Array(frameLen);
    pendingBuf.copy(Buffer.from(frame.buffer), 0, FRAME_HEADER_SIZE, totalLen);
    pendingBuf.copy(pendingBuf, 0, totalLen, pendingLen);
    pendingLen -= totalLen;

    if (frame[0] === CallTag.call) {
      handleCall(frame);
    } else {
      console.error("[v2] unexpected tag:", frame[0]);
      conn.destroy();
      return;
    }
  }
}

// --- CALL dispatch ---

function handleCall(frame: Uint8Array): void {
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
        dispatchPrefetch(requestId, args);
        break;
      case "handle":
        dispatchHandle(requestId, args);
        break;
      case "render":
        dispatchRender(requestId, args);
        break;
      default:
        console.error("[v2] unknown function:", name);
        sendFrame(conn, buildResult(requestId, ResultFlag.failure, new Uint8Array(0)));
    }
  } catch (e: any) {
    console.error(`[v2] ${name} error:`, e.message || e);
    sendFrame(conn, buildResult(requestId, ResultFlag.failure, new Uint8Array(0)));
  }
}

// --- RT1: route ---
// CALL args: [method: u8][path_len: u16 BE][path][body_len: u16 BE][body]
// RESULT: [operation: u8][id: 16 bytes LE]

function dispatchRoute(requestId: number, args: Uint8Array): void {
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

  if (!routeResult) {
    sendFrame(conn, buildResult(requestId, ResultFlag.failure, new Uint8Array(0)));
    return;
  }

  // Store per-request state.
  requests.set(requestId, {
    operation: matchedOp,
    id: (routeResult.id || "").replace(/-/g, ""),
    body: body.length > 0 ? JSON.parse(body) : {},
    params: routeResult.params || {},
    rows: [],
    status: "",
  });

  // Build result: [operation: u8][id: 16 bytes LE]
  const opValue = (OperationValues as any)[matchedOp];
  const idHex = (routeResult.id || "0".repeat(32)).replace(/-/g, "").padStart(32, "0");
  const resultData = new Uint8Array(1 + 16);
  resultData[0] = opValue;
  for (let i = 0; i < 16; i++) {
    resultData[1 + i] = parseInt(idHex.substr((15 - i) * 2, 2), 16);
  }

  sendFrame(conn, buildResult(requestId, ResultFlag.success, resultData));
}

// --- RT2: prefetch ---
// CALL args: [operation: u8][id: 16 bytes LE][params_json_len: u16 BE][params_json]
// RESULT: [sql_len: u16 BE][sql][param_count: u8][param values...]

function dispatchPrefetch(requestId: number, _args: Uint8Array): void {
  const req = requests.get(requestId);
  if (!req) {
    sendFrame(conn, buildResult(requestId, ResultFlag.failure, new Uint8Array(0)));
    return;
  }

  const mod = modules[req.operation];
  if (!mod?.prefetch) {
    // No prefetch — return empty query.
    sendFrame(conn, buildResult(requestId, ResultFlag.success, new Uint8Array(0)));
    return;
  }

  const msg = { operation: req.operation, id: req.id, body: req.body, ...req.params };
  const queryDecl = mod.prefetch(msg);

  // queryDecl is [sql, ...params] or empty array.
  if (!Array.isArray(queryDecl) || queryDecl.length === 0) {
    sendFrame(conn, buildResult(requestId, ResultFlag.success, new Uint8Array(0)));
    return;
  }

  const sql = String(queryDecl[0]);
  const params = queryDecl.slice(1);
  const sqlBytes = _encoder.encode(sql);

  // Build result: [sql_len: u16 BE][sql][param_count: u8][param_values...]
  // Param values: [type_tag: u8][value...] per param.
  // Type tags match protocol.zig TypeTag.
  const buf = new Uint8Array(FRAME_MAX);
  const bufDv = new DataView(buf.buffer);
  let pos = 0;

  bufDv.setUint16(pos, sqlBytes.length, false); pos += 2;
  buf.set(sqlBytes, pos); pos += sqlBytes.length;
  buf[pos] = params.length; pos += 1;

  for (const p of params) {
    if (p === null || p === undefined) {
      buf[pos] = 0x05; pos += 1; // null
    } else if (typeof p === "number") {
      buf[pos] = 0x01; pos += 1; // integer
      bufDv.setBigInt64(pos, BigInt(Math.trunc(p)), true); pos += 8;
    } else if (typeof p === "string") {
      buf[pos] = 0x03; pos += 1; // text
      const strBytes = _encoder.encode(p);
      bufDv.setUint16(pos, strBytes.length, false); pos += 2;
      buf.set(strBytes, pos); pos += strBytes.length;
    } else if (typeof p === "bigint") {
      buf[pos] = 0x01; pos += 1; // integer
      bufDv.setBigInt64(pos, p, true); pos += 8;
    } else {
      buf[pos] = 0x05; pos += 1; // unknown → null
    }
  }

  sendFrame(conn, buildResult(requestId, ResultFlag.success, buf.subarray(0, pos)));
}

// --- RT3: handle ---
// CALL args: [rows_data...] (binary row set from framework)
// RESULT: [status_len: u16 BE][status][session_action: u8][write_count: u8][writes...]

import { readRowSet } from "../generated/serde.ts";

const SessionAction = { none: 0, set_authenticated: 1, clear: 2 } as const;

function dispatchHandle(requestId: number, args: Uint8Array): void {
  const req = requests.get(requestId);
  if (!req) {
    sendFrame(conn, buildResult(requestId, ResultFlag.failure, new Uint8Array(0)));
    return;
  }

  // Parse rows from framework.
  if (args.length > 0) {
    try {
      const rowsDv = new DataView(args.buffer, args.byteOffset, args.byteLength);
      const { result } = readRowSet(rowsDv, 0);
      req.rows = result?.rows || [];
    } catch {
      req.rows = [];
    }
  }

  const mod = modules[req.operation];
  const writes: Array<[string, ...any[]]> = [];

  const ctx = {
    operation: req.operation,
    id: req.id,
    body: req.body,
    params: req.params,
    rows: req.rows,
    write: (decl: [string, ...any[]]) => { writes.push(decl); },
  };

  let status = "ok";
  let sessionAction = 0;

  if (mod?.handle) {
    const handleResult = mod.handle(ctx, { execute: (...args: any[]) => ctx.write(args as any) });
    if (typeof handleResult === "string") {
      status = handleResult || "ok";
    } else if (handleResult && typeof handleResult === "object") {
      status = (handleResult as any).status || "ok";
      const rawAction = (handleResult as any).sessionAction;
      if (rawAction !== undefined) {
        const mapped = SessionAction[rawAction as keyof typeof SessionAction];
        if (mapped !== undefined) sessionAction = mapped;
      }
    }
  }

  req.status = status;

  // Build result: [status_len: u16 BE][status][session_action: u8][write_count: u8][writes...]
  const statusBytes = _encoder.encode(status);
  const buf = new Uint8Array(FRAME_MAX);
  const bufDv = new DataView(buf.buffer);
  let pos = 0;

  bufDv.setUint16(pos, statusBytes.length, false); pos += 2;
  buf.set(statusBytes, pos); pos += statusBytes.length;
  buf[pos] = sessionAction; pos += 1;
  buf[pos] = writes.length; pos += 1;

  for (const w of writes) {
    const sql = String(w[0]);
    const params = w.slice(1);
    const sqlBytes = _encoder.encode(sql);
    bufDv.setUint16(pos, sqlBytes.length, false); pos += 2;
    buf.set(sqlBytes, pos); pos += sqlBytes.length;
    buf[pos] = params.length; pos += 1;

    for (const p of params) {
      if (p === null || p === undefined) {
        buf[pos] = 0x05; pos += 1;
      } else if (typeof p === "number") {
        buf[pos] = 0x01; pos += 1;
        bufDv.setBigInt64(pos, BigInt(Math.trunc(p)), true); pos += 8;
      } else if (typeof p === "boolean") {
        buf[pos] = 0x01; pos += 1;
        bufDv.setBigInt64(pos, BigInt(p ? 1 : 0), true); pos += 8;
      } else if (typeof p === "string") {
        buf[pos] = 0x03; pos += 1;
        const strBytes = _encoder.encode(p);
        bufDv.setUint16(pos, strBytes.length, false); pos += 2;
        buf.set(strBytes, pos); pos += strBytes.length;
      } else if (typeof p === "bigint") {
        buf[pos] = 0x01; pos += 1;
        bufDv.setBigInt64(pos, p, true); pos += 8;
      } else if (p instanceof Uint8Array) {
        buf[pos] = 0x04; pos += 1; // blob
        bufDv.setUint16(pos, p.length, false); pos += 2;
        buf.set(p, pos); pos += p.length;
      } else {
        buf[pos] = 0x05; pos += 1;
      }
    }
  }

  sendFrame(conn, buildResult(requestId, ResultFlag.success, buf.subarray(0, pos)));
}

// --- RT4: render ---
// CALL args: [status_byte: u8] (status enum value for convenience)
// RESULT: raw HTML bytes

import { StatusNames } from "../generated/types.generated.ts";

function dispatchRender(requestId: number, _args: Uint8Array): void {
  const req = requests.get(requestId);
  if (!req) {
    sendFrame(conn, buildResult(requestId, ResultFlag.failure, new Uint8Array(0)));
    return;
  }

  const mod = modules[req.operation];
  let html = "";

  if (mod?.render) {
    const ctx = {
      operation: req.operation,
      id: req.id,
      status: req.status,
      body: req.body,
      params: req.params,
      rows: req.rows,
      prefetched: { rows: req.rows }, // backward compat
      is_sse: false,
    };
    html = mod.render(ctx) || "";
  }

  // Cleanup — final RT for this request.
  requests.delete(requestId);

  const htmlBytes = _encoder.encode(html);
  sendFrame(conn, buildResult(requestId, ResultFlag.success, htmlBytes));
}

// --- TTL sweep for leaked entries ---

setInterval(() => {
  // In normal operation, render deletes the entry. If a request
  // is abandoned (framework crash, timeout), entries leak. Sweep
  // clears anything older than 10 seconds. The Map size is the
  // observable pipeline depth.
  if (requests.size > 0) {
    // Simple approach: clear all if the map is suspiciously large.
    // A more precise TTL would require timestamps per entry.
    // At pipeline_depth_max=128, anything above that is a leak.
    if (requests.size > 256) {
      console.warn(`[v2] clearing ${requests.size} leaked request entries`);
      requests.clear();
    }
  }
}, 10_000);
