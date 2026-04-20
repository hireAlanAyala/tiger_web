// Cross-language round-trip test for the binary row format.
// Hand-constructed binary matches what protocol.zig + storage.zig produce.
//
// Run:
//   ./zig/zig build unit-test   # generates packages/vectors/row_sets.bin
//   npx tsx generated/serde_test.ts
//
// The Zig tests MUST run first to generate the cross-language vector.
// CI must enforce this ordering.

import { readRowSet, writeParams, writeSqlDeclarations, writeWriteQueue, TypeTag, frame_max, columns_max, column_name_max, cell_value_max } from "./serde.ts";
import { OperationValues, StatusValues } from "./types.generated.ts";
import { readFileSync, existsSync } from "fs";

let passed = 0;

function assert(condition: boolean, msg: string): void {
  if (!condition) throw new Error("FAIL: " + msg);
}

function assertEq(actual: unknown, expected: unknown, msg: string): void {
  if (actual !== expected) throw new Error(`FAIL: ${msg}: expected ${expected}, got ${actual}`);
}

// --- Test 1: Read a row set with 3 columns, 1 row ---
// Matches the "query_raw: single row round trip" test in storage.zig.
// Columns: id(integer), name(text), price(integer)
// Row: id=42, name="Widget", price=999
{
  const bytes: number[] = [];

  // Header: 3 columns
  bytes.push(0x00, 0x03); // u16 BE col_count = 3

  // Column 0: integer, "id"
  bytes.push(TypeTag.integer); // type tag
  bytes.push(0x00, 0x02); // u16 BE name_len = 2
  bytes.push(0x69, 0x64); // "id"

  // Column 1: text, "name"
  bytes.push(TypeTag.text);
  bytes.push(0x00, 0x04); // name_len = 4
  bytes.push(0x6E, 0x61, 0x6D, 0x65); // "name"

  // Column 2: integer, "price"
  bytes.push(TypeTag.integer);
  bytes.push(0x00, 0x05); // name_len = 5
  bytes.push(0x70, 0x72, 0x69, 0x63, 0x65); // "price"

  // Row count: 1
  bytes.push(0x00, 0x00, 0x00, 0x01); // u32 BE

  // Row 1, col 0: integer 42 (i64 LE)
  bytes.push(42, 0, 0, 0, 0, 0, 0, 0);

  // Row 1, col 1: text "Widget" (u16 BE len + bytes)
  bytes.push(0x00, 0x06); // len = 6
  bytes.push(0x57, 0x69, 0x64, 0x67, 0x65, 0x74); // "Widget"

  // Row 1, col 2: integer 999 (i64 LE)
  bytes.push(0xE7, 0x03, 0, 0, 0, 0, 0, 0); // 999 = 0x3E7

  const buf = new DataView(new Uint8Array(bytes).buffer);
  const { result, offset } = readRowSet(buf, 0);

  assertEq(result.columns.length, 3, "col count");
  assertEq(result.columns[0].name, "id", "col 0 name");
  assertEq(result.columns[0].typeTag, TypeTag.integer, "col 0 type");
  assertEq(result.columns[1].name, "name", "col 1 name");
  assertEq(result.columns[1].typeTag, TypeTag.text, "col 1 type");
  assertEq(result.columns[2].name, "price", "col 2 name");

  assertEq(result.rows.length, 1, "row count");
  assertEq(result.rows[0].id, 42, "row 0 id");
  assertEq(result.rows[0].name, "Widget", "row 0 name");
  assertEq(result.rows[0].price, 999, "row 0 price");
  assertEq(offset, bytes.length, "offset at end");

  passed++;
}

// --- Test 2: Empty row set (0 rows) ---
{
  const bytes: number[] = [];
  bytes.push(0x00, 0x01); // 1 column
  bytes.push(TypeTag.null); // type tag (null for empty results)
  bytes.push(0x00, 0x02); // name_len = 2
  bytes.push(0x69, 0x64); // "id"
  bytes.push(0x00, 0x00, 0x00, 0x00); // row count = 0

  const buf = new DataView(new Uint8Array(bytes).buffer);
  const { result } = readRowSet(buf, 0);

  assertEq(result.columns.length, 1, "empty: col count");
  assertEq(result.rows.length, 0, "empty: row count");

  passed++;
}

// --- Test 3: Multiple rows ---
{
  const bytes: number[] = [];
  bytes.push(0x00, 0x02); // 2 columns

  bytes.push(TypeTag.integer);
  bytes.push(0x00, 0x02);
  bytes.push(0x69, 0x64); // "id"

  bytes.push(TypeTag.text);
  bytes.push(0x00, 0x03);
  bytes.push(0x76, 0x61, 0x6C); // "val"

  bytes.push(0x00, 0x00, 0x00, 0x03); // 3 rows

  // Row 1: id=1, val="alpha"
  bytes.push(1, 0, 0, 0, 0, 0, 0, 0);
  bytes.push(0x00, 0x05);
  bytes.push(0x61, 0x6C, 0x70, 0x68, 0x61);

  // Row 2: id=2, val="beta"
  bytes.push(2, 0, 0, 0, 0, 0, 0, 0);
  bytes.push(0x00, 0x04);
  bytes.push(0x62, 0x65, 0x74, 0x61);

  // Row 3: id=3, val="gamma"
  bytes.push(3, 0, 0, 0, 0, 0, 0, 0);
  bytes.push(0x00, 0x05);
  bytes.push(0x67, 0x61, 0x6D, 0x6D, 0x61);

  const buf = new DataView(new Uint8Array(bytes).buffer);
  const { result } = readRowSet(buf, 0);

  assertEq(result.rows.length, 3, "multi: row count");
  assertEq(result.rows[0].id, 1, "multi: row 0 id");
  assertEq(result.rows[0].val, "alpha", "multi: row 0 val");
  assertEq(result.rows[1].id, 2, "multi: row 1 id");
  assertEq(result.rows[1].val, "beta", "multi: row 1 val");
  assertEq(result.rows[2].id, 3, "multi: row 2 id");
  assertEq(result.rows[2].val, "gamma", "multi: row 2 val");

  passed++;
}

// --- Test 4: Null values ---
{
  const bytes: number[] = [];
  bytes.push(0x00, 0x02); // 2 columns

  bytes.push(TypeTag.integer);
  bytes.push(0x00, 0x02);
  bytes.push(0x69, 0x64); // "id"

  bytes.push(TypeTag.null);
  bytes.push(0x00, 0x04);
  bytes.push(0x64, 0x65, 0x73, 0x63); // "desc"

  bytes.push(0x00, 0x00, 0x00, 0x01); // 1 row

  // Row 1: id=7, desc=null
  bytes.push(7, 0, 0, 0, 0, 0, 0, 0);
  // null: 0 bytes

  const buf = new DataView(new Uint8Array(bytes).buffer);
  const { result } = readRowSet(buf, 0);

  assertEq(result.rows.length, 1, "null: row count");
  assertEq(result.rows[0].id, 7, "null: id");
  assertEq(result.rows[0].desc, null, "null: desc is null");

  passed++;
}

// --- Test 5: Float value ---
{
  const bytes: number[] = [];
  bytes.push(0x00, 0x01); // 1 column
  bytes.push(TypeTag.float);
  bytes.push(0x00, 0x05);
  bytes.push(0x70, 0x72, 0x69, 0x63, 0x65); // "price"
  bytes.push(0x00, 0x00, 0x00, 0x01); // 1 row

  // f64 3.14 as u64 LE bytes.
  const fbuf = new ArrayBuffer(8);
  new Float64Array(fbuf)[0] = 3.14;
  const fbytes = new Uint8Array(fbuf);
  for (const b of fbytes) bytes.push(b);

  const buf = new DataView(new Uint8Array(bytes).buffer);
  const { result } = readRowSet(buf, 0);

  assertEq(result.rows[0].price, 3.14, "float: price");

  passed++;
}

// --- Test 6: Param writer round-trip ---
{
  const paramBuf = new ArrayBuffer(256);
  const dv = new DataView(paramBuf);

  const params: unknown[] = [42, "hello", true, null, 3.14];
  const bytesWritten = writeParams(dv, 0, params);

  assert(bytesWritten > 0, "params: wrote bytes");

  // Verify the wire format manually.
  let pos = 0;

  // Param 0: integer 42
  assertEq(dv.getUint8(pos), TypeTag.integer, "param 0 tag");
  pos += 1;
  assertEq(dv.getUint32(pos, true), 42, "param 0 lo");
  assertEq(dv.getInt32(pos + 4, true), 0, "param 0 hi");
  pos += 8;

  // Param 1: text "hello"
  assertEq(dv.getUint8(pos), TypeTag.text, "param 1 tag");
  pos += 1;
  assertEq(dv.getUint16(pos, false), 5, "param 1 len");
  pos += 2;
  const textBytes = new Uint8Array(paramBuf, pos, 5);
  assertEq(new TextDecoder().decode(textBytes), "hello", "param 1 text");
  pos += 5;

  // Param 2: integer 1 (boolean true)
  assertEq(dv.getUint8(pos), TypeTag.integer, "param 2 tag");
  pos += 1;
  assertEq(dv.getUint32(pos, true), 1, "param 2 val");
  pos += 8;

  // Param 3: null
  assertEq(dv.getUint8(pos), TypeTag.null, "param 3 tag");
  pos += 1;

  // Param 4: float 3.14
  assertEq(dv.getUint8(pos), TypeTag.float, "param 4 tag");
  pos += 1;
  assertEq(dv.getFloat64(pos, true), 3.14, "param 4 val");
  pos += 8;

  assertEq(pos, bytesWritten, "param total bytes");

  passed++;
}

// --- Test 7: SQL declaration writer ---
{
  const buf = new ArrayBuffer(1024);
  const dv = new DataView(buf);

  const decls = [
    { key: "product", sql: "SELECT id FROM products WHERE id = ?1", mode: "query" as const, params: [42] },
    { key: "orders", sql: "SELECT id FROM orders", mode: "queryAll" as const, params: [] },
  ];

  const bytesWritten = writeSqlDeclarations(dv, 0, decls);
  assert(bytesWritten > 0, "decl: wrote bytes");

  // Verify query count.
  assertEq(dv.getUint8(0), 2, "decl: count");

  passed++;
}

// --- Test 8: Write queue writer ---
{
  const buf = new ArrayBuffer(1024);
  const dv = new DataView(buf);

  const writes = [
    { sql: "INSERT INTO t VALUES (?1, ?2)", params: [1, "test"] },
  ];

  const bytesWritten = writeWriteQueue(dv, 0, writes);
  assert(bytesWritten > 0, "writes: wrote bytes");

  // Verify write count.
  assertEq(dv.getUint8(0), 1, "writes: count");

  passed++;
}

// --- Test 9: Negative integers ---
{
  const bytes: number[] = [];
  bytes.push(0x00, 0x01); // 1 column
  bytes.push(TypeTag.integer);
  bytes.push(0x00, 0x03);
  bytes.push(0x76, 0x61, 0x6C); // "val"
  bytes.push(0x00, 0x00, 0x00, 0x02); // 2 rows

  // Row 1: val = -1 (i64 LE: all FF)
  bytes.push(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);
  // Row 2: val = -42 (i64 LE: 0xFFFFFFFFFFFFFFD6)
  bytes.push(0xD6, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);

  const buf = new DataView(new Uint8Array(bytes).buffer);
  const { result } = readRowSet(buf, 0);

  assertEq(result.rows[0].val, -1, "neg: -1");
  assertEq(result.rows[1].val, -42, "neg: -42");

  passed++;
}

// --- Test 10: Negative integer param writer round-trip ---
{
  const paramBuf = new ArrayBuffer(64);
  const dv = new DataView(paramBuf);

  const bytesWritten = writeParams(dv, 0, [-42]);
  assertEq(dv.getUint8(0), TypeTag.integer, "neg param: tag");
  // Read back the i64 LE value.
  const lo = dv.getUint32(1, true);
  const hi = dv.getInt32(5, true);
  const val = hi * 0x100000000 + lo;
  assertEq(val, -42, "neg param: value");
  assertEq(bytesWritten, 9, "neg param: bytes");

  passed++;
}

// --- Test 11: Blob value in row set ---
{
  const bytes: number[] = [];
  bytes.push(0x00, 0x01); // 1 column
  bytes.push(TypeTag.blob);
  bytes.push(0x00, 0x04);
  bytes.push(0x64, 0x61, 0x74, 0x61); // "data"
  bytes.push(0x00, 0x00, 0x00, 0x01); // 1 row

  // Row 1: data = [0xDE, 0xAD, 0xBE, 0xEF]
  bytes.push(0x00, 0x04); // u16 BE len = 4
  bytes.push(0xDE, 0xAD, 0xBE, 0xEF);

  const buf = new DataView(new Uint8Array(bytes).buffer);
  const { result } = readRowSet(buf, 0);

  const blob = result.rows[0].data as Uint8Array;
  assert(blob instanceof Uint8Array, "blob: is Uint8Array");
  assertEq(blob.length, 4, "blob: length");
  assertEq(blob[0], 0xDE, "blob[0]");
  assertEq(blob[1], 0xAD, "blob[1]");
  assertEq(blob[2], 0xBE, "blob[2]");
  assertEq(blob[3], 0xEF, "blob[3]");

  passed++;
}

// --- Test 12: MAX_SAFE_INTEGER serialized as integer, not float ---
{
  const paramBuf = new ArrayBuffer(64);
  const dv = new DataView(paramBuf);

  writeParams(dv, 0, [Number.MAX_SAFE_INTEGER]);
  assertEq(dv.getUint8(0), TypeTag.integer, "max_safe: tag is integer not float");

  passed++;
}

// --- Test 13: Direct cross-language test vector ---
// Reads packages/vectors/row_sets.bin written by protocol.zig unit test.
// Run `zig build unit-test` first to generate the file.
{
  const vectorPath = "packages/vectors/row_sets.bin";
  if (existsSync(vectorPath)) {
    const fileBytes = readFileSync(vectorPath);
    const buf = new DataView(fileBytes.buffer, fileBytes.byteOffset, fileBytes.byteLength);
    const { result } = readRowSet(buf, 0);

    // 5 columns: id, name, price, data, score
    assertEq(result.columns.length, 5, "xlang: col count");
    assertEq(result.columns[0].name, "id", "xlang: col 0");
    assertEq(result.columns[1].name, "name", "xlang: col 1");
    assertEq(result.columns[2].name, "price", "xlang: col 2");
    assertEq(result.columns[3].name, "data", "xlang: col 3");
    assertEq(result.columns[4].name, "score", "xlang: col 4");

    // 2 rows
    assertEq(result.rows.length, 2, "xlang: row count");

    // Row 1: id=42, name="Widget", price=-1, data=[0xDE,0xAD], score=3.14
    assertEq(result.rows[0].id, 42, "xlang: r0 id");
    assertEq(result.rows[0].name, "Widget", "xlang: r0 name");
    assertEq(result.rows[0].price, -1, "xlang: r0 price");
    const blob0 = result.rows[0].data as Uint8Array;
    assertEq(blob0.length, 2, "xlang: r0 data len");
    assertEq(blob0[0], 0xDE, "xlang: r0 data[0]");
    assertEq(blob0[1], 0xAD, "xlang: r0 data[1]");
    assertEq(result.rows[0].score, 3.14, "xlang: r0 score");

    // Row 2: id=0, name="", price=999, data=[], score=-0.0
    assertEq(result.rows[1].id, 0, "xlang: r1 id");
    assertEq(result.rows[1].name, "", "xlang: r1 name");
    assertEq(result.rows[1].price, 999, "xlang: r1 price");
    const blob1 = result.rows[1].data as Uint8Array;
    assertEq(blob1.length, 0, "xlang: r1 data len");
    // -0.0: Object.is distinguishes -0 from +0
    assert(Object.is(result.rows[1].score, -0), "xlang: r1 score is -0");

    passed++;
    console.log("  (cross-language vector test passed)");
  } else {
    console.log("  (skipped cross-language test — run `zig build unit-test` first to generate vector)");
  }
}

// --- Test 14: Cross-language enum mapping verification ---
// Reads packages/vectors/enums.json written by protocol.zig unit test.
// Verifies that OperationValues and StatusValues in types.generated.ts
// match the Zig enum values exactly.
{
  const enumPath = "packages/vectors/enums.json";
  if (existsSync(enumPath)) {
    const data = JSON.parse(readFileSync(enumPath, "utf-8"));

    // Verify operations.
    for (const [name, value] of Object.entries(data.operations)) {
      assertEq(OperationValues[name], value, `operation ${name}`);
    }
    // Verify TS doesn't have extra operations.
    for (const name of Object.keys(OperationValues)) {
      assert(name in data.operations, `TS has operation '${name}' not in Zig`);
    }

    // Verify statuses.
    for (const [name, value] of Object.entries(data.statuses)) {
      assertEq(StatusValues[name], value, `status ${name}`);
    }
    for (const name of Object.keys(StatusValues)) {
      assert(name in data.statuses, `TS has status '${name}' not in Zig`);
    }

    // Verify constants match between Zig and TS.
    const c = data.constants;
    assertEq(frame_max, c.frame_max, "constant frame_max");
    assertEq(columns_max, c.columns_max, "constant columns_max");
    assertEq(column_name_max, c.column_name_max, "constant column_name_max");
    assertEq(cell_value_max, c.cell_value_max, "constant cell_value_max");

    passed++;
    console.log("  (cross-language enum + constants test passed)");
  } else {
    console.log("  (skipped enum mapping test — run `zig build unit-test` first)");
  }
}

console.log(`${passed} serde tests passed`);
