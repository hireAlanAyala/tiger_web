// Cross-language test for CALL/RESULT protocol frames.
// Reads packages/vectors/frames.bin written by protocol.zig unit tests.
//
// Run:
//   ./zig/zig build unit-test   # generates packages/vectors/frames.bin
//   npx tsx generated/call_test.ts
//
// Verifies that TS parses the same bytes as Zig writes, catching
// serialization mismatches across the language boundary.

import { readRowSet, TypeTag } from "./serde.ts";
import { readFileSync } from "fs";

const CallTag = {
  call: 0x10,
  result: 0x11,
  query: 0x12,
  query_result: 0x13,
} as const;

const ResultFlag = { success: 0x00, failure: 0x01 } as const;
const QueryMode = { query: 0x00, queryAll: 0x01 } as const;

let passed = 0;

function assert(condition: boolean, msg: string): void {
  if (!condition) throw new Error("FAIL: " + msg);
}

function assertEq(actual: unknown, expected: unknown, msg: string): void {
  if (actual !== expected) throw new Error(`FAIL: ${msg}: expected ${expected}, got ${actual}`);
}

// Read the vector file.
const vectorPath = "packages/vectors/frames.bin";
const data = readFileSync(vectorPath);
const dv = new DataView(data.buffer, data.byteOffset, data.byteLength);
let pos = 0;

const frameCount = data[pos]; pos += 1;
assertEq(frameCount, 4, "frame count");

// Helper: read one frame (u32 BE length + payload).
function readFrame(): { payload: Uint8Array; dv: DataView } {
  const len = dv.getUint32(pos, false); pos += 4;
  const payload = new Uint8Array(data.buffer, data.byteOffset + pos, len);
  pos += len;
  return {
    payload,
    dv: new DataView(payload.buffer, payload.byteOffset, payload.byteLength),
  };
}

// --- Frame 0: CALL ---
// request_id=1, name="prefetch", args=[op=0x14, id=0x01..0x10]
{
  const { payload, dv: fdv } = readFrame();
  assertEq(payload[0], CallTag.call, "frame 0: tag");
  assertEq(fdv.getUint32(1, false), 1, "frame 0: request_id");
  const nameLen = fdv.getUint16(5, false);
  assertEq(nameLen, 8, "frame 0: name_len");
  const name = new TextDecoder().decode(payload.subarray(7, 7 + nameLen));
  assertEq(name, "prefetch", "frame 0: name");
  const args = payload.subarray(7 + nameLen);
  assertEq(args[0], 0x14, "frame 0: args operation");
  // ID bytes 0x01..0x10
  for (let i = 0; i < 16; i++) {
    assertEq(args[1 + i], i + 1, `frame 0: args id byte ${i}`);
  }
  passed++;
  console.log("  CALL frame: OK");
}

// --- Frame 1: RESULT ---
// request_id=1, flag=success, data=[status_len=2, "ok", write_count=0]
{
  const { payload, dv: fdv } = readFrame();
  assertEq(payload[0], CallTag.result, "frame 1: tag");
  assertEq(fdv.getUint32(1, false), 1, "frame 1: request_id");
  assertEq(payload[5], ResultFlag.success, "frame 1: flag");
  // data starts at offset 6
  const dataPayload = payload.subarray(6);
  const statusLen = new DataView(dataPayload.buffer, dataPayload.byteOffset).getUint16(0, false);
  assertEq(statusLen, 2, "frame 1: status_len");
  const status = new TextDecoder().decode(dataPayload.subarray(2, 2 + statusLen));
  assertEq(status, "ok", "frame 1: status");
  assertEq(dataPayload[2 + statusLen], 0, "frame 1: write_count");
  passed++;
  console.log("  RESULT frame: OK");
}

// --- Frame 2: QUERY ---
// request_id=1, query_id=7, sql="SELECT id FROM products WHERE id = ?1",
// mode=query, param_count=1, param=[text, "test_value"]
{
  const { payload, dv: fdv } = readFrame();
  assertEq(payload[0], CallTag.query, "frame 2: tag");
  assertEq(fdv.getUint32(1, false), 1, "frame 2: request_id");
  assertEq(fdv.getUint16(5, false), 7, "frame 2: query_id");
  const sqlLen = fdv.getUint16(7, false);
  const expectedSql = "SELECT id FROM products WHERE id = ?1";
  assertEq(sqlLen, expectedSql.length, "frame 2: sql_len");
  const sql = new TextDecoder().decode(payload.subarray(9, 9 + sqlLen));
  assertEq(sql, expectedSql, "frame 2: sql");
  let p = 9 + sqlLen;
  assertEq(payload[p], QueryMode.query, "frame 2: mode");
  p += 1;
  assertEq(payload[p], 1, "frame 2: param_count");
  p += 1;
  // param: text "test_value"
  assertEq(payload[p], TypeTag.text, "frame 2: param type");
  p += 1;
  const paramLen = new DataView(payload.buffer, payload.byteOffset + p).getUint16(0, false);
  assertEq(paramLen, 10, "frame 2: param len");
  p += 2;
  const paramVal = new TextDecoder().decode(payload.subarray(p, p + paramLen));
  assertEq(paramVal, "test_value", "frame 2: param value");
  passed++;
  console.log("  QUERY frame: OK");
}

// --- Frame 3: QUERY_RESULT ---
// request_id=1, query_id=7, row_set=[1 col "id" integer, 1 row, value=42]
{
  const { payload, dv: fdv } = readFrame();
  assertEq(payload[0], CallTag.query_result, "frame 3: tag");
  assertEq(fdv.getUint32(1, false), 1, "frame 3: request_id");
  assertEq(fdv.getUint16(5, false), 7, "frame 3: query_id");
  // row_set starts at offset 7
  const rowSetData = payload.subarray(7);
  const rowSetDv = new DataView(rowSetData.buffer, rowSetData.byteOffset, rowSetData.byteLength);
  const { result } = readRowSet(rowSetDv, 0);
  assertEq(result.columns.length, 1, "frame 3: col count");
  assertEq(result.columns[0].name, "id", "frame 3: col name");
  assertEq(result.columns[0].typeTag, TypeTag.integer, "frame 3: col type");
  assertEq(result.rows.length, 1, "frame 3: row count");
  assertEq(result.rows[0].id, 42, "frame 3: row value");
  passed++;
  console.log("  QUERY_RESULT frame: OK");
}

console.log(`\nAll ${passed} CALL/RESULT vector tests passed.`);
