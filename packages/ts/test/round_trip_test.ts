// Round-trip test — validates generated protocol code against committed vectors.
//
// 1. Build frames with generated builders → parse back → assert equality
// 2. Parse committed vectors/frames.bin with generated parsers → assert values
// 3. Verify constants match primitives.json
//
// Run: npx tsx packages/ts/test/round_trip_test.ts

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  TypeTag, CallTag, ResultFlag, QueryMode,
  frame_max, columns_max, column_name_max, cell_value_max, sql_max, writes_max,
  RegionHeader, SlotHeader,
  buildCallFrame, buildResultFrame, buildReadyFrame,
  parseCallFrame, parseResultFrame,
} from "../src/protocol_generated.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const vectorsDir = resolve(__dirname, "../../vectors");

function assert(condition: boolean, msg: string) {
  if (!condition) { console.error(`FAIL: ${msg}`); process.exit(1); }
}

let passed = 0;

// === 1. Constants match primitives.json ===
{
  const primitives = JSON.parse(readFileSync(resolve(vectorsDir, "primitives.json"), "utf-8"));

  assert(TypeTag.integer === primitives.type_tags.integer, "TypeTag.integer");
  assert(TypeTag.float === primitives.type_tags.float, "TypeTag.float");
  assert(TypeTag.text === primitives.type_tags.text, "TypeTag.text");
  assert(TypeTag.blob === primitives.type_tags.blob, "TypeTag.blob");
  assert(TypeTag.null === primitives.type_tags.null, "TypeTag.null");

  assert(CallTag.call === primitives.call_tags.call, "CallTag.call");
  assert(CallTag.result === primitives.call_tags.result, "CallTag.result");
  assert(CallTag.query === primitives.call_tags.query, "CallTag.query");
  assert(CallTag.query_result === primitives.call_tags.query_result, "CallTag.query_result");
  assert(CallTag.ready === primitives.call_tags.ready, "CallTag.ready");

  assert(frame_max === primitives.constants.frame_max, "frame_max");
  assert(columns_max === primitives.constants.columns_max, "columns_max");
  assert(column_name_max === primitives.constants.column_name_max, "column_name_max");
  assert(cell_value_max === primitives.constants.cell_value_max, "cell_value_max");
  assert(sql_max === primitives.constants.sql_max, "sql_max");
  assert(writes_max === primitives.constants.writes_max, "writes_max");

  passed++;
  console.log("  Constants match primitives.json: OK");
}

// === 2. SHM layout offsets match shm_layout.json ===
{
  const layout = JSON.parse(readFileSync(resolve(vectorsDir, "shm_layout.json"), "utf-8"));

  assert(RegionHeader.size === layout.region_header.size, "RegionHeader.size");
  assert(RegionHeader.slot_count.offset === layout.region_header.fields.slot_count.offset, "slot_count offset");
  assert(RegionHeader.frame_max.offset === layout.region_header.fields.frame_max.offset, "frame_max offset");

  assert(SlotHeader.size === layout.slot_header.size, "SlotHeader.size");
  assert(SlotHeader.server_seq.offset === layout.slot_header.fields.server_seq.offset, "server_seq offset");
  assert(SlotHeader.sidecar_seq.offset === layout.slot_header.fields.sidecar_seq.offset, "sidecar_seq offset");
  assert(SlotHeader.request_len.offset === layout.slot_header.fields.request_len.offset, "request_len offset");
  assert(SlotHeader.response_len.offset === layout.slot_header.fields.response_len.offset, "response_len offset");
  assert(SlotHeader.request_crc.offset === layout.slot_header.fields.request_crc.offset, "request_crc offset");
  assert(SlotHeader.response_crc.offset === layout.slot_header.fields.response_crc.offset, "response_crc offset");
  assert(SlotHeader.slot_state.offset === layout.slot_header.fields.slot_state.offset, "slot_state offset");

  passed++;
  console.log("  SHM layout matches shm_layout.json: OK");
}

// === 3. Round-trip: build CALL → parse → assert ===
{
  const buf = new Uint8Array(256);
  const args = new TextEncoder().encode("test_args");
  const len = buildCallFrame(buf, 42, "handle_render", args);

  const parsed = parseCallFrame(buf.subarray(0, len));
  assert(parsed !== null, "CALL round-trip parse");
  assert(parsed!.requestId === 42, "CALL requestId");
  assert(parsed!.name === "handle_render", "CALL name");
  assert(new TextDecoder().decode(parsed!.args) === "test_args", "CALL args");

  passed++;
  console.log("  CALL frame round-trip: OK");
}

// === 4. Round-trip: build RESULT → parse → assert ===
{
  const buf = new Uint8Array(256);
  const payload = new TextEncoder().encode("ok_data");
  const len = buildResultFrame(buf, 99, ResultFlag.success, payload);

  const parsed = parseResultFrame(buf.subarray(0, len));
  assert(parsed !== null, "RESULT round-trip parse");
  assert(parsed!.requestId === 99, "RESULT requestId");
  assert(parsed!.flag === ResultFlag.success, "RESULT flag");
  assert(new TextDecoder().decode(parsed!.payload) === "ok_data", "RESULT payload");

  passed++;
  console.log("  RESULT frame round-trip: OK");
}

// === 5. Round-trip: build READY → verify bytes ===
{
  const buf = new Uint8Array(16);
  const len = buildReadyFrame(buf, 1);
  assert(len === 3, "READY frame length");
  assert(buf[0] === CallTag.ready, "READY tag");
  const dv = new DataView(buf.buffer);
  assert(dv.getUint16(1, false) === 1, "READY version");

  passed++;
  console.log("  READY frame build: OK");
}

// === 6. Parse committed frames.bin with generated parsers ===
{
  const data = readFileSync(resolve(vectorsDir, "frames.bin"));
  const dv = new DataView(data.buffer, data.byteOffset, data.byteLength);

  const frameCount = data[0];
  assert(frameCount === 4, "frames.bin frame count");
  let pos = 1;

  // Frame 0: CALL
  const callLen = dv.getUint32(pos, false); pos += 4;
  const callData = data.subarray(pos, pos + callLen); pos += callLen;
  const call = parseCallFrame(callData);
  assert(call !== null, "frames.bin CALL parse");
  assert(call!.requestId === 1, "frames.bin CALL requestId");
  assert(call!.name === "prefetch", "frames.bin CALL name");

  // Frame 1: RESULT
  const resultLen = dv.getUint32(pos, false); pos += 4;
  const resultData = data.subarray(pos, pos + resultLen); pos += resultLen;
  const result = parseResultFrame(resultData);
  assert(result !== null, "frames.bin RESULT parse");
  assert(result!.requestId === 1, "frames.bin RESULT requestId");
  assert(result!.flag === ResultFlag.success, "frames.bin RESULT flag");

  passed++;
  console.log("  Committed frames.bin validated: OK");
}

// === 7. Parser rejects garbage ===
{
  assert(parseCallFrame(new Uint8Array(0)) === null, "empty CALL");
  assert(parseCallFrame(new Uint8Array([0xFF])) === null, "wrong tag CALL");
  assert(parseCallFrame(new Uint8Array([0x10, 0, 0, 0, 1, 0xFF, 0xFF])) === null, "truncated CALL name");
  assert(parseResultFrame(new Uint8Array(0)) === null, "empty RESULT");
  assert(parseResultFrame(new Uint8Array([0xFF])) === null, "wrong tag RESULT");

  passed++;
  console.log("  Parser rejection tests: OK");
}

console.log(`\nAll ${passed} round-trip tests passed.`);
