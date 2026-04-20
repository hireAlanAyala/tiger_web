#!/usr/bin/env -S npx tsx
// Protocol codegen — generates TypeScript constants and types from
// the committed protocol vectors (primitives.json, shm_layout.json).
//
// The vectors are the source of truth. This script reads them and
// produces protocol_generated.ts with all constants, enums, offsets,
// and frame builder/parser functions.
//
// Run: npx tsx packages/ts/src/gen/generate_protocol.ts
// Output: packages/ts/src/protocol_generated.ts
//
// When to re-run: after any change to packages/vectors/*.json.
// CI asserts the generated output matches committed — same governance
// as the binary vectors themselves.

import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const vectorsDir = resolve(__dirname, "../../../vectors");
const outputPath = resolve(__dirname, "../protocol_generated.ts");

// Read vector sources.
const primitives = JSON.parse(readFileSync(resolve(vectorsDir, "primitives.json"), "utf-8"));
const shmLayout = JSON.parse(readFileSync(resolve(vectorsDir, "shm_layout.json"), "utf-8"));

let out = `// AUTO-GENERATED from packages/vectors/ — do not edit.
// Regenerate: npx tsx packages/ts/src/gen/generate_protocol.ts
//
// Source of truth: primitives.json, shm_layout.json, crc_vectors.json
// Any mismatch between this file and the vectors is a bug.

`;

// --- Enums ---
out += `// === Type Tags ===\n`;
out += `export const TypeTag = {\n`;
for (const [name, value] of Object.entries(primitives.type_tags)) {
  out += `  ${name}: ${value},\n`;
}
out += `} as const;\n\n`;

out += `export const CallTag = {\n`;
for (const [name, value] of Object.entries(primitives.call_tags)) {
  out += `  ${name}: ${value},\n`;
}
out += `} as const;\n\n`;

out += `export const ResultFlag = {\n`;
for (const [name, value] of Object.entries(primitives.result_flags)) {
  out += `  ${name}: ${value},\n`;
}
out += `} as const;\n\n`;

out += `export const QueryMode = {\n`;
for (const [name, value] of Object.entries(primitives.query_modes)) {
  out += `  ${name}: ${value},\n`;
}
out += `} as const;\n\n`;

out += `export const SlotState = {\n  free: 0,\n  call_written: 1,\n  result_written: 2,\n} as const;\n\n`;

// --- Constants ---
out += `// === Protocol Constants ===\n`;
for (const [name, value] of Object.entries(primitives.constants)) {
  out += `export const ${name} = ${value};\n`;
}
out += `\n`;

// --- SHM Layout Offsets ---
out += `// === SHM Region Header (${shmLayout.region_header.size} bytes) ===\n`;
out += `export const RegionHeader = {\n`;
out += `  size: ${shmLayout.region_header.size},\n`;
for (const [name, field] of Object.entries(shmLayout.region_header.fields) as [string, any][]) {
  if (name.startsWith("_")) continue;
  out += `  ${name}: { offset: ${field.offset}, size: ${field.size} },\n`;
}
out += `} as const;\n\n`;

out += `// === SHM Slot Header (${shmLayout.slot_header.size} bytes) ===\n`;
out += `export const SlotHeader = {\n`;
out += `  size: ${shmLayout.slot_header.size},\n`;
for (const [name, field] of Object.entries(shmLayout.slot_header.fields) as [string, any][]) {
  if (name.startsWith("_")) continue;
  out += `  ${name}: { offset: ${field.offset}, size: ${field.size} },\n`;
}
out += `} as const;\n\n`;

// --- Frame Builders ---
out += `// === Frame Builders ===\n\n`;
out += `// Pre-allocated encoder — never allocate in the hot path.\n`;
out += `const _encoder = new TextEncoder();\n\n`;

out += `/** Build a CALL frame: [tag:0x10][request_id: u32 BE][name_len: u16 BE][name][args] */
export function buildCallFrame(buf: Uint8Array, requestId: number, name: string, args: Uint8Array): number {
  const nameBytes = _encoder.encode(name);
  const needed = 7 + nameBytes.length + args.length;
  if (needed > buf.length) throw new RangeError(\`CALL frame (\${needed}B) exceeds buffer (\${buf.length}B)\`);
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let pos = 0;
  buf[pos] = CallTag.call; pos += 1;
  dv.setUint32(pos, requestId, false); pos += 4;
  dv.setUint16(pos, nameBytes.length, false); pos += 2;
  buf.set(nameBytes, pos); pos += nameBytes.length;
  buf.set(args, pos); pos += args.length;
  return pos;
}

`;

out += `/** Build a RESULT frame: [tag:0x11][request_id: u32 BE][flag: u8][payload] */
export function buildResultFrame(buf: Uint8Array, requestId: number, flag: number, payload: Uint8Array): number {
  const needed = 6 + payload.length;
  if (needed > buf.length) throw new RangeError(\`RESULT frame (\${needed}B) exceeds buffer (\${buf.length}B)\`);
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let pos = 0;
  buf[pos] = CallTag.result; pos += 1;
  dv.setUint32(pos, requestId, false); pos += 4;
  buf[pos] = flag; pos += 1;
  buf.set(payload, pos); pos += payload.length;
  return pos;
}

`;

out += `/** Build a READY frame: [tag:0x20][version: u16 BE] */
export function buildReadyFrame(buf: Uint8Array, version: number): number {
  if (buf.length < 3) throw new RangeError("READY frame requires at least 3 bytes");
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let pos = 0;
  buf[pos] = CallTag.ready; pos += 1;
  dv.setUint16(pos, version, false); pos += 2;
  return pos;
}

`;

// --- Frame Parsers ---
out += `// === Frame Parsers ===\n\n`;

out += `export interface ParsedCall { requestId: number; name: string; args: Uint8Array; }

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

`;

out += `export interface ParsedResult { requestId: number; flag: number; payload: Uint8Array; }

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

`;

out += `// === CRC Convention ===\n`;
out += `// CRC32-ISO-HDLC (IEEE polynomial 0xEDB88320).\n`;
out += `// Computed over: u32le(payload_len) ++ payload_bytes.\n`;
out += `// Use: import { crc32 } from "node:zlib";\n`;
out += `//      const lenBuf = Buffer.alloc(4); lenBuf.writeUInt32LE(payload.length);\n`;
out += `//      const crc = crc32(Buffer.concat([lenBuf, payload]));\n`;

writeFileSync(outputPath, out);
console.log(`Generated: ${outputPath} (${out.length} bytes)`);
