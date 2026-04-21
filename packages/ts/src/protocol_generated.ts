// AUTO-GENERATED from packages/vectors/ — do not edit.
// Regenerate: npx tsx packages/ts/src/gen/generate_protocol.ts
//
// Source of truth: primitives.json, shm_layout.json, crc_vectors.json
// Any mismatch between this file and the vectors is a bug.

// === Type Tags ===
export const TypeTag = {
  integer: 1,
  float: 2,
  text: 3,
  blob: 4,
  null: 5,
} as const;

export const CallTag = {
  call: 16,
  result: 17,
  query: 18,
  query_result: 19,
  ready: 32,
} as const;

export const ResultFlag = {
  success: 0,
  failure: 1,
} as const;

export const QueryMode = {
  query: 0,
  query_all: 1,
} as const;

export const SlotState = {
  free: 0,
  call_written: 1,
  result_written: 2,
} as const;

// === Protocol Constants ===
export const frame_max = 262144;
export const columns_max = 32;
export const column_name_max = 128;
export const cell_value_max = 4096;
export const sql_max = 4096;
export const writes_max = 21;

// === SHM Region Header (64 bytes) ===
export const RegionHeader = {
  size: 64,
  slot_count: { offset: 0, size: 2 },
  frame_max: { offset: 4, size: 4 },
} as const;

// === SHM Slot Header (64 bytes) ===
export const SlotHeader = {
  size: 64,
  server_seq: { offset: 0, size: 4 },
  sidecar_seq: { offset: 4, size: 4 },
  request_len: { offset: 8, size: 4 },
  response_len: { offset: 12, size: 4 },
  request_crc: { offset: 16, size: 4 },
  response_crc: { offset: 20, size: 4 },
  slot_state: { offset: 24, size: 1 },
} as const;

// === Frame Builders ===

// Pre-allocated encoder — never allocate in the hot path.
const _encoder = new TextEncoder();

/** Build a CALL frame: [tag:0x10][request_id: u32 BE][name_len: u16 BE][name][args] */
export function buildCallFrame(buf: Uint8Array, requestId: number, name: string, args: Uint8Array): number {
  const nameBytes = _encoder.encode(name);
  const needed = 7 + nameBytes.length + args.length;
  if (needed > buf.length) throw new RangeError(`CALL frame (${needed}B) exceeds buffer (${buf.length}B)`);
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let pos = 0;
  buf[pos] = CallTag.call; pos += 1;
  dv.setUint32(pos, requestId, false); pos += 4;
  dv.setUint16(pos, nameBytes.length, false); pos += 2;
  buf.set(nameBytes, pos); pos += nameBytes.length;
  buf.set(args, pos); pos += args.length;
  return pos;
}

/** Build a RESULT frame: [tag:0x11][request_id: u32 BE][flag: u8][payload] */
export function buildResultFrame(buf: Uint8Array, requestId: number, flag: number, payload: Uint8Array): number {
  const needed = 6 + payload.length;
  if (needed > buf.length) throw new RangeError(`RESULT frame (${needed}B) exceeds buffer (${buf.length}B)`);
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let pos = 0;
  buf[pos] = CallTag.result; pos += 1;
  dv.setUint32(pos, requestId, false); pos += 4;
  buf[pos] = flag; pos += 1;
  buf.set(payload, pos); pos += payload.length;
  return pos;
}

/** Build a READY frame: [tag:0x20][version: u16 BE] */
export function buildReadyFrame(buf: Uint8Array, version: number): number {
  if (buf.length < 3) throw new RangeError("READY frame requires at least 3 bytes");
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let pos = 0;
  buf[pos] = CallTag.ready; pos += 1;
  dv.setUint16(pos, version, false); pos += 2;
  return pos;
}

// === Frame Parsers ===

export interface ParsedCall { requestId: number; name: string; args: Uint8Array; }

/** Parse a CALL frame. Returns null if invalid. */
export function parseCallFrame(data: Uint8Array): ParsedCall | null {
  if (data.length < 7) return null;
  if (data[0] !== CallTag.call) return null;
  const dv = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const requestId = dv.getUint32(1, false);
  const nameLen = dv.getUint16(5, false);
  if (7 + nameLen > data.length) return null;
  const name = new TextDecoder().decode(data.subarray(7, 7 + nameLen));
  const args = data.subarray(7 + nameLen);
  return { requestId, name, args };
}

export interface ParsedResult { requestId: number; flag: number; payload: Uint8Array; }

/** Parse a RESULT frame. Returns null if invalid. */
export function parseResultFrame(data: Uint8Array): ParsedResult | null {
  if (data.length < 6) return null;
  if (data[0] !== CallTag.result) return null;
  const dv = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const requestId = dv.getUint32(1, false);
  const flag = data[5];
  const payload = data.subarray(6);
  return { requestId, flag, payload };
}

// === CRC Convention ===
// CRC32-ISO-HDLC (IEEE polynomial 0xEDB88320).
// Computed over: u32le(payload_len) ++ payload_bytes.
// Use: import { crc32 } from "node:zlib";
//      const lenBuf = Buffer.alloc(4); lenBuf.writeUInt32LE(payload.length);
//      const crc = crc32(Buffer.concat([lenBuf, payload]));
