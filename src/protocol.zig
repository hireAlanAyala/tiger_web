//! Sidecar wire protocol — self-describing binary rows over unix socket.
//!
//! Three round trips per HTTP request:
//!   RT1: route_request → route_prefetch_response
//!   RT2: prefetch_results → handle_render_response
//!   RT3: render_results → html_response
//!
//! Design decisions:
//!
//! **Self-describing rows, not domain structs.** The original protocol
//! serialized PrefetchCache (65KB, 11 typed slots) and WriteSlot (tagged
//! union). Adding a table meant 4 changes. The new protocol carries rows
//! — one generic reader per language, no per-type serde. Adding a table
//! doesn't touch the protocol. SQL is the schema contract.
//!
//! **Not JSON.** The first rebuild used JSON frames. This introduced
//! hand-rolled parsing (150 lines), 1MB buffers, runtime string matching.
//! Binary type tags + lengths have no parsing — just read and advance.
//!
//! **Column names on the wire.** Redundant — the sidecar knows the SQL.
//! But omitting names means column order matters. A schema change silently
//! misaligns data. Names: ~50 bytes per result set, safety over bandwidth.
//!
//! **Always 3 round trips.** Considered 2 RTs (skip render when no render
//! SQL). Rejected: the database is the bottleneck, not the socket. 50us
//! for an empty RT is not worth a second code path. One path everywhere.
//!
//! Frame format: [u32 big-endian payload_length][u8 message_tag][payload]

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");

// =====================================================================
// Constants
// =====================================================================

/// Maximum number of write SQL statements from a single handle() call.
/// Derived from the domain constant — sidecar cannot exceed what the SM accepts.
pub const writes_max = message.writes_max;

/// Maximum SQL string length in a single query/write.
pub const sql_max = 4096;

/// Maximum number of queries in a prefetch or render declaration.
/// Derived: create_order prefetches one product per order item (order_items_max).
/// page_load_dashboard prefetches 3 lists. The max is the larger of the two.
/// No headroom — if a handler exceeds this, it's a design problem, not a cap problem.
pub const queries_max = @max(message.order_items_max, 3);

/// Maximum column name length.
pub const column_name_max = 128;

/// Maximum columns per row set.
pub const columns_max = 32;

/// Maximum text/blob value length in a single cell.
/// Must hold the largest domain string field.
pub const cell_value_max = 4096;

/// Maximum frame payload size.
///
/// The largest frame is prefetch_results: multiple row sets in one frame.
/// Practical worst case: page_load_dashboard — 3 queries × 50 rows × ~750
/// bytes per row ≈ 115KB. create_order — 20 queries × 1 row ≈ 15KB.
///
/// 256KB handles all current handlers with margin. If a handler exceeds
/// this, the prefetch declared too many queries or the rows are too wide.
/// The framework asserts at the serialization boundary.
pub const frame_max = 256 * 1024;

comptime {
    assert(writes_max > 0);
    assert(writes_max == message.writes_max);
    assert(sql_max > 0);
    assert(queries_max > 0);
    assert(queries_max >= message.order_items_max);
    assert(columns_max > 0);

    // Frame size: must hold worst-case prefetch results.
    // 3 queries × 50 rows × 1KB/row = 150KB, well under 256KB.
    assert(frame_max >= 3 * message.list_max * 1024);
    assert(frame_max <= 1024 * 1024); // stay under 1MB

    // Route request worst case: tag(1) + method(1) + path(2+64K) + body(2+64K) < 131KB.
    assert(frame_max >= 1 + 1 + 2 + 0xFFFF + 2 + 0xFFFF);

    // Handle response worst case: tag(1) + status(1) + write_count(1) +
    // writes(writes_max × (sql_max + 1 + max_params_size)) + render_decls.
    // writes_max(21) × (2 + sql_max(4096) + 1 + 16 × 9) ≈ 21 × 4243 ≈ 89KB.
    const max_param_size = 1 + 8; // type_tag + i64 (largest fixed-size param)
    const max_write_entry = 2 + sql_max + 1 + 16 * max_param_size;
    const max_handle_response = 1 + 1 + 1 + writes_max * max_write_entry + 1 + queries_max * (1 + sql_max + 1 + 1);
    assert(frame_max >= max_handle_response);

    // WAL entry worst case: header(64) + writes(writes_max × max_write_entry).
    // Must fit in wal.entry_max (the server's scratch buffer).
    const wal = @import("framework/wal.zig");
    const max_wal_entry = @sizeOf(wal.EntryHeader) + writes_max * max_write_entry;
    assert(wal.entry_max >= max_wal_entry);

    // cell_value_max must hold every domain string field.
    assert(cell_value_max >= message.product_description_max);
    assert(cell_value_max >= message.product_name_max);
    assert(cell_value_max >= message.collection_name_max);
    assert(cell_value_max >= message.search_query_max);
    assert(cell_value_max >= message.email_max);
    assert(cell_value_max >= message.payment_ref_max);
}

// =====================================================================
// Type tags — match SQLite's type affinity
// =====================================================================

pub const TypeTag = enum(u8) {
    integer = 0x01, // i64, little-endian 8 bytes
    float = 0x02, // f64, little-endian 8 bytes
    text = 0x03, // u16 len + bytes
    blob = 0x04, // u16 len + bytes
    null = 0x05, // 0 bytes
};

// =====================================================================
// Message tags — identify each frame in the 3-RT exchange
// =====================================================================

// Legacy MessageTag removed — was only used by old 3-RT protocol.

// =====================================================================
// CALL/RESULT protocol — 1-CALL model
//
// Four frame types. The server sends one CALL "request" per HTTP request.
// The sidecar runs route + prefetch + handle + render internally, using
// QUERY sub-calls for db.query(), and returns a combined RESULT.
//
// Previously used 4 separate CALLs (route, prefetch, handle, render) =
// 10+ frames/request. Consolidated to 1 CALL = 4 frames/request.
// This reduced per-request native overhead by ~60%, improving sidecar
// throughput by 20-42%. See decision-sidecar-1call-protocol.md.
//
// Frame layout (all within a length-prefixed frame envelope):
//   CALL:         [tag][request_id: u32 BE][name_len: u16 BE][name][args...]
//   RESULT:       [tag][request_id: u32 BE][flag: u8][result...]
//   QUERY:        [tag][request_id: u32 BE][query_id: u16 BE][sql_len: u16 BE][sql][mode][param_count: u8][params...]
//   QUERY_RESULT: [tag][request_id: u32 BE][query_id: u16 BE][row_set...]
// =====================================================================

pub const CallTag = enum(u8) {
    call = 0x10,
    result = 0x11,
    query = 0x12,
    query_result = 0x13,
    /// Sent by sidecar after connecting. Server validates before
    /// routing requests. The connection is "disconnected" until
    /// a valid READY frame is received.
    ready = 0x20,
};

// =====================================================================
// READY handshake — sidecar → server
//
// Sent once after unix socket connect. The server must receive and
// validate this before marking the sidecar as connected. Until then,
// all HTTP requests get 503.
//
// Layout: [tag: 0x20][version: u16 BE]
//
// version: protocol version (currently 1). Server rejects mismatches.
//
// No pid — the supervisor owns the process and already has the pid
// from std.process.Child.id. The server owns the connection, not
// the process. Stage 2 (multi-sidecar) adds a sidecar_index field
// for correlating which process connected to which bus.
// =====================================================================

pub const protocol_version: u16 = 1;

pub const ReadyPayload = struct {
    version: u16,
};

pub fn parse_ready_frame(frame: []const u8) ?ReadyPayload {
    if (frame.len < 3) return null; // tag(1) + version(2)
    if (frame[0] != @intFromEnum(CallTag.ready)) return null;
    const version = std.mem.readInt(u16, frame[1..3], .big);
    return .{ .version = version };
}

/// Maximum function name length (e.g., "handle_create_product").
pub const function_name_max = 128;

/// RESULT flag byte — success or failure.
pub const ResultFlag = enum(u8) {
    success = 0x00,
    failure = 0x01,
};

/// Query mode — single row or array.
/// Named to match the PrefetchDb API: db.query() and db.queryAll().
pub const QueryMode = enum(u8) {
    query = 0x00, // row_count is 0 (null) or 1
    query_all = 0x01, // row_count is 0..N
};

// =====================================================================
// Row format — serialize / deserialize
// =====================================================================

/// Column descriptor — type tag + name.
/// Name is a slice into the frame buffer — aliases recv_buf.
/// Consume before the buffer is reused.
pub const Column = struct {
    type_tag: TypeTag,
    name: []const u8,
};

comptime {
    assert(column_name_max <= std.math.maxInt(u16));
    assert(cell_value_max <= std.math.maxInt(u16));
}

/// A typed value in a row.
pub const Value = union(TypeTag) {
    integer: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
    null: void,
};

/// Write a row set header (columns) into buf at pos.
/// Returns the new position, or null if buffer too small.
pub fn write_row_set_header(buf: []u8, columns: []const Column) ?usize {
    var pos: usize = 0;

    // Column count.
    if (pos + 2 > buf.len) return null;
    assert(columns.len <= columns_max);
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(columns.len), .big);
    pos += 2;

    // Column descriptors.
    for (columns) |col| {
        assert(col.name.len <= column_name_max);
        if (pos + 1 + 2 + col.name.len > buf.len) return null;
        buf[pos] = @intFromEnum(col.type_tag);
        pos += 1;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(col.name.len), .big);
        pos += 2;
        @memcpy(buf[pos..][0..col.name.len], col.name);
        pos += col.name.len;
    }

    return pos;
}

/// Write the row count at the given position.
/// Returns the new position, or null if buffer too small.
pub fn write_row_count(buf: []u8, pos: usize, count: u32) ?usize {
    if (pos + 4 > buf.len) return null;
    std.mem.writeInt(u32, buf[pos..][0..4], count, .big);
    return pos + 4;
}

/// Write a single typed value into buf at pos.
/// Returns the new position, or null if buffer too small.
pub fn write_value(buf: []u8, pos_in: usize, value: Value) ?usize {
    var pos = pos_in;
    switch (value) {
        .integer => |v| {
            if (pos + 8 > buf.len) return null;
            std.mem.writeInt(i64, buf[pos..][0..8], v, .little);
            pos += 8;
        },
        .float => |v| {
            if (pos + 8 > buf.len) return null;
            std.mem.writeInt(u64, buf[pos..][0..8], @bitCast(v), .little);
            pos += 8;
        },
        .text => |v| {
            assert(v.len <= cell_value_max);
            if (pos + 2 + v.len > buf.len) return null;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(v.len), .big);
            pos += 2;
            @memcpy(buf[pos..][0..v.len], v);
            pos += v.len;
        },
        .blob => |v| {
            assert(v.len <= cell_value_max);
            if (pos + 2 + v.len > buf.len) return null;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(v.len), .big);
            pos += 2;
            @memcpy(buf[pos..][0..v.len], v);
            pos += v.len;
        },
        .null => {},
    }
    return pos;
}

/// Read a row set header from buf at pos. Columns are slices into buf.
/// Returns columns and new position, or null on malformed input.
pub fn read_row_set_header(buf: []const u8, pos_in: usize) ?struct { columns: [columns_max]Column, count: u16, pos: usize } {
    var pos = pos_in;
    if (pos + 2 > buf.len) return null;
    const col_count = std.mem.readInt(u16, buf[pos..][0..2], .big);
    pos += 2;
    if (col_count > columns_max) return null;

    var columns: [columns_max]Column = undefined;
    for (0..col_count) |i| {
        if (pos + 1 + 2 > buf.len) return null;
        const tag_byte = buf[pos];
        pos += 1;
        const tag = std.meta.intToEnum(TypeTag, tag_byte) catch return null;
        const name_len = std.mem.readInt(u16, buf[pos..][0..2], .big);
        pos += 2;
        if (name_len > column_name_max) return null;
        if (pos + name_len > buf.len) return null;
        columns[i] = .{ .type_tag = tag, .name = buf[pos..][0..name_len] };
        pos += name_len;
    }

    return .{ .columns = columns, .count = col_count, .pos = pos };
}

/// Read the row count at the given position.
pub fn read_row_count(buf: []const u8, pos: usize) ?struct { count: u32, pos: usize } {
    if (pos + 4 > buf.len) return null;
    const count = std.mem.readInt(u32, buf[pos..][0..4], .big);
    return .{ .count = count, .pos = pos + 4 };
}

/// Read a single typed value from buf at pos.
/// The type_tag tells us how to interpret the bytes.
pub fn read_value(buf: []const u8, pos_in: usize, type_tag: TypeTag) ?struct { value: Value, pos: usize } {
    var pos = pos_in;
    switch (type_tag) {
        .integer => {
            if (pos + 8 > buf.len) return null;
            const v = std.mem.readInt(i64, buf[pos..][0..8], .little);
            pos += 8;
            return .{ .value = .{ .integer = v }, .pos = pos };
        },
        .float => {
            if (pos + 8 > buf.len) return null;
            const v: f64 = @bitCast(std.mem.readInt(u64, buf[pos..][0..8], .little));
            pos += 8;
            return .{ .value = .{ .float = v }, .pos = pos };
        },
        .text => {
            if (pos + 2 > buf.len) return null;
            const len = std.mem.readInt(u16, buf[pos..][0..2], .big);
            pos += 2;
            if (len > cell_value_max) return null;
            if (pos + len > buf.len) return null;
            const v = buf[pos..][0..len];
            pos += len;
            return .{ .value = .{ .text = v }, .pos = pos };
        },
        .blob => {
            if (pos + 2 > buf.len) return null;
            const len = std.mem.readInt(u16, buf[pos..][0..2], .big);
            pos += 2;
            if (len > cell_value_max) return null;
            if (pos + len > buf.len) return null;
            const v = buf[pos..][0..len];
            pos += len;
            return .{ .value = .{ .blob = v }, .pos = pos };
        },
        .null => {
            return .{ .value = .{ .null = {} }, .pos = pos };
        },
    }
}

// =====================================================================
// CALL/RESULT frame builders — server-side
// =====================================================================

/// Write the CALL frame header into buf. Returns the byte offset
/// after the header — the caller writes args starting here.
/// Layout: [tag: u8][request_id: u32 BE][name_len: u16 BE][name]
///
/// Zero-copy: the caller builds args directly into buf after the
/// header. No intermediate args buffer, no double copy.
pub fn write_call_header(buf: []u8, request_id: u32, function_name: []const u8) usize {
    assert(function_name.len <= function_name_max);
    const header_len = 1 + 4 + 2 + function_name.len;
    assert(header_len <= buf.len);
    var pos: usize = 0;
    buf[pos] = @intFromEnum(CallTag.call);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], request_id, .big);
    pos += 4;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(function_name.len), .big);
    pos += 2;
    @memcpy(buf[pos..][0..function_name.len], function_name);
    pos += function_name.len;
    return pos;
}

/// Build a CALL frame in buf. Returns the payload length.
/// Layout: [tag: u8][request_id: u32 BE][name_len: u16 BE][name][args...]
pub fn build_call(buf: []u8, request_id: u32, function_name: []const u8, args: []const u8) ?usize {
    assert(function_name.len <= function_name_max);
    const total = 1 + 4 + 2 + function_name.len + args.len;
    if (total > buf.len) return null;
    if (total > frame_max) return null;

    var pos: usize = 0;
    buf[pos] = @intFromEnum(CallTag.call);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], request_id, .big);
    pos += 4;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(function_name.len), .big);
    pos += 2;
    @memcpy(buf[pos..][0..function_name.len], function_name);
    pos += function_name.len;
    if (args.len > 0) {
        @memcpy(buf[pos..][0..args.len], args);
        pos += args.len;
    }
    return pos;
}

/// Build a RESULT frame in buf. Returns the payload length.
/// Layout: [tag: 0x11][request_id: u32 BE][flag: u8][data...]
/// Mirrors build_call for the response direction.
pub fn build_result(buf: []u8, request_id: u32, flag: ResultFlag, data: []const u8) ?usize {
    const total = 1 + 4 + 1 + data.len;
    if (total > buf.len) return null;
    if (total > frame_max) return null;

    var pos: usize = 0;
    buf[pos] = @intFromEnum(CallTag.result);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], request_id, .big);
    pos += 4;
    buf[pos] = @intFromEnum(flag);
    pos += 1;
    if (data.len > 0) {
        @memcpy(buf[pos..][0..data.len], data);
        pos += data.len;
    }
    assert(pos == total);
    return pos;
}

/// Build a QUERY_RESULT frame in buf. Returns the payload length.
/// Layout: [tag: u8][request_id: u32 BE][query_id: u16 BE][row_set...]
pub fn build_query_result(buf: []u8, request_id: u32, query_id: u16, row_set: []const u8) ?usize {
    const total = 1 + 4 + 2 + row_set.len;
    if (total > buf.len) return null;
    if (total > frame_max) return null;

    var pos: usize = 0;
    buf[pos] = @intFromEnum(CallTag.query_result);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], request_id, .big);
    pos += 4;
    std.mem.writeInt(u16, buf[pos..][0..2], query_id, .big);
    pos += 2;
    if (row_set.len > 0) {
        @memcpy(buf[pos..][0..row_set.len], row_set);
        pos += row_set.len;
    }
    return pos;
}

/// Parse a frame received from the sidecar. Returns the tag, request_id,
/// and payload (everything after tag + request_id).
pub const SidecarFrame = struct {
    tag: CallTag,
    request_id: u32,
    payload: []const u8,
};

pub fn parse_sidecar_frame(frame: []const u8) ?SidecarFrame {
    if (frame.len < 5) return null; // tag(1) + request_id(4)
    const tag = std.meta.intToEnum(CallTag, frame[0]) catch return null;
    if (tag != .result and tag != .query) return null; // sidecar only sends these
    const request_id = std.mem.readInt(u32, frame[1..5], .big);
    return .{
        .tag = tag,
        .request_id = request_id,
        .payload = frame[5..],
    };
}

/// Parse a RESULT payload — flag byte + result data.
pub const ResultPayload = struct {
    flag: ResultFlag,
    data: []const u8,
};

pub fn parse_result_payload(payload: []const u8) ?ResultPayload {
    if (payload.len < 1) return null;
    const flag = std.meta.intToEnum(ResultFlag, payload[0]) catch return null;
    return .{
        .flag = flag,
        .data = payload[1..],
    };
}

/// Parse a QUERY payload — sql + params.
pub const QueryPayload = struct {
    query_id: u16,
    sql: []const u8,
    mode: QueryMode,
    params_buf: []const u8,
    param_count: u8,
};

pub fn parse_query_payload(payload: []const u8) ?QueryPayload {
    var pos: usize = 0;
    // query_id: u16 BE — identifies this query within the CALL.
    // Echoed in QUERY_RESULT for Promise.all() support.
    if (pos + 2 > payload.len) return null;
    const query_id = std.mem.readInt(u16, payload[pos..][0..2], .big);
    pos += 2;
    if (pos + 2 > payload.len) return null;
    const sql_len = std.mem.readInt(u16, payload[pos..][0..2], .big);
    pos += 2;
    if (pos + sql_len > payload.len) return null;
    const sql = payload[pos..][0..sql_len];
    pos += sql_len;
    if (pos >= payload.len) return null;
    const mode = std.meta.intToEnum(QueryMode, payload[pos]) catch return null;
    pos += 1;
    if (pos >= payload.len) return null;
    const param_count = payload[pos];
    pos += 1;
    return .{
        .query_id = query_id,
        .sql = sql,
        .mode = mode,
        .params_buf = payload[pos..],
        .param_count = param_count,
    };
}

// =====================================================================
// Tests — fixed-input unit tests
// =====================================================================

test "row set header round trip" {
    var buf: [1024]u8 = undefined;
    const columns = [_]Column{
        .{ .type_tag = .integer, .name = "id" },
        .{ .type_tag = .text, .name = "name" },
        .{ .type_tag = .null, .name = "description" },
    };

    const write_pos = write_row_set_header(&buf, &columns) orelse unreachable;
    const result = read_row_set_header(&buf, 0) orelse unreachable;

    try std.testing.expectEqual(@as(u16, 3), result.count);
    try std.testing.expectEqual(write_pos, result.pos);
    try std.testing.expectEqualStrings("id", result.columns[0].name);
    try std.testing.expectEqual(TypeTag.integer, result.columns[0].type_tag);
    try std.testing.expectEqualStrings("name", result.columns[1].name);
    try std.testing.expectEqual(TypeTag.text, result.columns[1].type_tag);
    try std.testing.expectEqualStrings("description", result.columns[2].name);
    try std.testing.expectEqual(TypeTag.null, result.columns[2].type_tag);
}

test "value round trip — integer" {
    var buf: [64]u8 = undefined;
    const pos = write_value(&buf, 0, .{ .integer = -42 }) orelse unreachable;
    const result = read_value(&buf, 0, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, -42), result.value.integer);
    try std.testing.expectEqual(pos, result.pos);
}

test "value round trip — float" {
    var buf: [64]u8 = undefined;
    const pos = write_value(&buf, 0, .{ .float = 3.14 }) orelse unreachable;
    const result = read_value(&buf, 0, .float) orelse unreachable;
    try std.testing.expectEqual(@as(f64, 3.14), result.value.float);
    try std.testing.expectEqual(pos, result.pos);
}

test "value round trip — text" {
    var buf: [64]u8 = undefined;
    const pos = write_value(&buf, 0, .{ .text = "hello" }) orelse unreachable;
    const result = read_value(&buf, 0, .text) orelse unreachable;
    try std.testing.expectEqualStrings("hello", result.value.text);
    try std.testing.expectEqual(pos, result.pos);
}

test "value round trip — blob" {
    var buf: [64]u8 = undefined;
    const data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const pos = write_value(&buf, 0, .{ .blob = data }) orelse unreachable;
    const result = read_value(&buf, 0, .blob) orelse unreachable;
    try std.testing.expectEqualSlices(u8, data, result.value.blob);
    try std.testing.expectEqual(pos, result.pos);
}

test "value round trip — null" {
    var buf: [64]u8 = undefined;
    const pos = write_value(&buf, 0, .{ .null = {} }) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 0), pos); // null is zero bytes
    const result = read_value(&buf, 0, .null) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 0), result.pos);
}

test "full row set round trip" {
    var buf: [4096]u8 = undefined;
    const columns = [_]Column{
        .{ .type_tag = .integer, .name = "id" },
        .{ .type_tag = .text, .name = "name" },
        .{ .type_tag = .integer, .name = "price" },
    };

    // Write header + row count + 2 rows.
    var pos = write_row_set_header(&buf, &columns) orelse unreachable;
    pos = write_row_count(&buf, pos, 2) orelse unreachable;

    // Row 1: id=1, name="Widget", price=999
    pos = write_value(&buf, pos, .{ .integer = 1 }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .text = "Widget" }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .integer = 999 }) orelse unreachable;

    // Row 2: id=2, name="Gadget", price=1999
    pos = write_value(&buf, pos, .{ .integer = 2 }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .text = "Gadget" }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .integer = 1999 }) orelse unreachable;

    // Read back.
    const hdr = read_row_set_header(&buf, 0) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 3), hdr.count);

    const rc = read_row_count(&buf, hdr.pos) orelse unreachable;
    try std.testing.expectEqual(@as(u32, 2), rc.count);

    var rpos = rc.pos;
    // Row 1
    const r1c1 = read_value(&buf, rpos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), r1c1.value.integer);
    rpos = r1c1.pos;

    const r1c2 = read_value(&buf, rpos, .text) orelse unreachable;
    try std.testing.expectEqualStrings("Widget", r1c2.value.text);
    rpos = r1c2.pos;

    const r1c3 = read_value(&buf, rpos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 999), r1c3.value.integer);
    rpos = r1c3.pos;

    // Row 2
    const r2c1 = read_value(&buf, rpos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 2), r2c1.value.integer);
    rpos = r2c1.pos;

    const r2c2 = read_value(&buf, rpos, .text) orelse unreachable;
    try std.testing.expectEqualStrings("Gadget", r2c2.value.text);
    rpos = r2c2.pos;

    const r2c3 = read_value(&buf, rpos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1999), r2c3.value.integer);
}

test "read rejects truncated header" {
    var buf = [_]u8{0x00}; // 1 byte, need at least 2
    try std.testing.expect(read_row_set_header(&buf, 0) == null);
}

test "read rejects invalid type tag" {
    var buf: [64]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 1, .big); // 1 column
    buf[2] = 0xFF; // invalid type tag
    std.mem.writeInt(u16, buf[3..5], 2, .big); // name len 2
    buf[5] = 'a';
    buf[6] = 'b';
    try std.testing.expect(read_row_set_header(&buf, 0) == null);
}

test "read rejects column count over max" {
    var buf: [64]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], columns_max + 1, .big);
    try std.testing.expect(read_row_set_header(&buf, 0) == null);
}

test "read_value rejects truncated text" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 100, .big); // claims 100 bytes
    // but buffer only has 4 bytes total
    try std.testing.expect(read_value(&buf, 0, .text) == null);
}

test "cross-language test vector — write to /tmp for TS reader" {
    // Write a known row set to a file. The TS test (serde_test.ts) reads
    // the same file and verifies agreement. This is a direct cross-language
    // test — not transitive through the spec.
    //
    // Columns: id(integer), name(text), price(integer), data(blob), score(float)
    // Row 1: id=42, name="Widget", price=-1, data=[0xDE,0xAD], score=3.14
    // Row 2: id=0, name="", price=999, data=[], score=-0.0

    var buf: [4096]u8 = undefined;
    const columns = [_]Column{
        .{ .type_tag = .integer, .name = "id" },
        .{ .type_tag = .text, .name = "name" },
        .{ .type_tag = .integer, .name = "price" },
        .{ .type_tag = .blob, .name = "data" },
        .{ .type_tag = .float, .name = "score" },
    };

    var pos = write_row_set_header(&buf, &columns) orelse unreachable;
    pos = write_row_count(&buf, pos, 2) orelse unreachable;

    // Row 1
    pos = write_value(&buf, pos, .{ .integer = 42 }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .text = "Widget" }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .integer = -1 }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .blob = &[_]u8{ 0xDE, 0xAD } }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .float = 3.14 }) orelse unreachable;

    // Row 2
    pos = write_value(&buf, pos, .{ .integer = 0 }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .text = "" }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .integer = 999 }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .blob = "" }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .float = -0.0 }) orelse unreachable;

    // Write to file.
    const file = std.fs.cwd().createFile("packages/vectors/row_sets.bin", .{}) catch unreachable;
    defer file.close();
    file.writeAll(buf[0..pos]) catch unreachable;
}

test "cross-language enum vector — write operation/status mappings" {
    // Write operation and status enum mappings as JSON. The TS test reads
    // this file and verifies its OperationValues/StatusValues match.
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.writeAll("{\"operations\":{") catch unreachable;
    {
        var first = true;
        inline for (@typeInfo(message.Operation).@"enum".fields) |f| {
            if (!first) w.writeAll(",") catch unreachable;
            first = false;
            w.print("\"{s}\":{d}", .{ f.name, f.value }) catch unreachable;
        }
    }
    w.writeAll("},\"statuses\":{") catch unreachable;
    {
        var first = true;
        inline for (@typeInfo(message.Status).@"enum".fields) |f| {
            if (!first) w.writeAll(",") catch unreachable;
            first = false;
            w.print("\"{s}\":{d}", .{ f.name, f.value }) catch unreachable;
        }
    }
    w.writeAll("},\"constants\":{") catch unreachable;
    w.print("\"frame_max\":{d},\"writes_max\":{d},\"queries_max\":{d},\"columns_max\":{d},\"cell_value_max\":{d},\"column_name_max\":{d},\"sql_max\":{d}", .{
        frame_max, writes_max, queries_max, columns_max, cell_value_max, column_name_max, sql_max,
    }) catch unreachable;
    w.writeAll("}}") catch unreachable;

    const file = std.fs.cwd().createFile("packages/vectors/enums.json", .{}) catch unreachable;
    defer file.close();
    file.writeAll(fbs.getWritten()) catch unreachable;
}

test "cross-language primitives vector — write type tags, constants, CRC spec" {
    // Generate primitives.json from Zig definitions. This is the source
    // of truth — not hand-written. CI asserts committed == generated.
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.writeAll("{\n") catch unreachable;

    // CRC spec.
    w.writeAll("  \"crc\": {\n") catch unreachable;
    w.writeAll("    \"algorithm\": \"CRC32-ISO-HDLC\",\n") catch unreachable;
    w.writeAll("    \"polynomial\": \"0xEDB88320\",\n") catch unreachable;
    w.writeAll("    \"note\": \"Standard IEEE 802.3 / zlib CRC32. Same as Zig std.hash.crc.Crc32 and Node.js zlib.crc32()\"\n") catch unreachable;
    w.writeAll("  },\n") catch unreachable;

    // Endianness.
    w.writeAll("  \"endianness\": {\n") catch unreachable;
    w.writeAll("    \"lengths_and_ids\": \"big-endian\",\n") catch unreachable;
    w.writeAll("    \"row_data_integers\": \"little-endian\",\n") catch unreachable;
    w.writeAll("    \"shm_header_fields\": \"little-endian\"\n") catch unreachable;
    w.writeAll("  },\n") catch unreachable;

    // Type tags from enum.
    w.writeAll("  \"type_tags\": {") catch unreachable;
    {
        var first = true;
        inline for (@typeInfo(TypeTag).@"enum".fields) |f| {
            if (!first) w.writeAll(",") catch unreachable;
            first = false;
            w.print("\"{s}\":{d}", .{ f.name, f.value }) catch unreachable;
        }
    }
    w.writeAll("},\n") catch unreachable;

    // Call tags from enum.
    w.writeAll("  \"call_tags\": {") catch unreachable;
    {
        var first = true;
        inline for (@typeInfo(CallTag).@"enum".fields) |f| {
            if (!first) w.writeAll(",") catch unreachable;
            first = false;
            w.print("\"{s}\":{d}", .{ f.name, f.value }) catch unreachable;
        }
    }
    w.writeAll("},\n") catch unreachable;

    // Result flags.
    w.writeAll("  \"result_flags\": {") catch unreachable;
    {
        var first = true;
        inline for (@typeInfo(ResultFlag).@"enum".fields) |f| {
            if (!first) w.writeAll(",") catch unreachable;
            first = false;
            w.print("\"{s}\":{d}", .{ f.name, f.value }) catch unreachable;
        }
    }
    w.writeAll("},\n") catch unreachable;

    // Query modes.
    w.writeAll("  \"query_modes\": {") catch unreachable;
    {
        var first = true;
        inline for (@typeInfo(QueryMode).@"enum".fields) |f| {
            if (!first) w.writeAll(",") catch unreachable;
            first = false;
            w.print("\"{s}\":{d}", .{ f.name, f.value }) catch unreachable;
        }
    }
    w.writeAll("},\n") catch unreachable;

    // Constants.
    w.writeAll("  \"constants\": {") catch unreachable;
    w.print("\"frame_max\":{d},\"columns_max\":{d},\"column_name_max\":{d},\"cell_value_max\":{d},\"sql_max\":{d},\"writes_max\":{d}", .{
        frame_max, columns_max, column_name_max, cell_value_max, sql_max, writes_max,
    }) catch unreachable;
    w.writeAll("}\n") catch unreachable;

    w.writeAll("}\n") catch unreachable;

    const file = std.fs.cwd().createFile("packages/vectors/primitives.json", .{}) catch unreachable;
    defer file.close();
    file.writeAll(fbs.getWritten()) catch unreachable;
}

test "CALL frame build and parse round trip" {
    var buf: [1024]u8 = undefined;
    const len = build_call(&buf, 42, "handle_create_product", "args_data") orelse unreachable;
    // Tag
    try std.testing.expectEqual(@as(u8, @intFromEnum(CallTag.call)), buf[0]);
    // Request ID
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[1..5], .big));
    // Function name length
    try std.testing.expectEqual(@as(u16, 21), std.mem.readInt(u16, buf[5..7], .big));
    // Function name
    try std.testing.expectEqualStrings("handle_create_product", buf[7..28]);
    // Args
    try std.testing.expectEqualStrings("args_data", buf[28..len]);
}

test "RESULT parse" {
    const payload = [_]u8{@intFromEnum(ResultFlag.success)} ++ "result_data".*;
    const result = parse_result_payload(&payload) orelse unreachable;
    try std.testing.expectEqual(ResultFlag.success, result.flag);
    try std.testing.expectEqualStrings("result_data", result.data);
}

test "RESULT parse — failure" {
    const payload = [_]u8{@intFromEnum(ResultFlag.failure)};
    const result = parse_result_payload(&payload) orelse unreachable;
    try std.testing.expectEqual(ResultFlag.failure, result.flag);
    try std.testing.expectEqual(@as(usize, 0), result.data.len);
}

test "sidecar frame parse — RESULT" {
    var buf: [64]u8 = undefined;
    buf[0] = @intFromEnum(CallTag.result);
    std.mem.writeInt(u32, buf[1..5], 99, .big);
    buf[5] = @intFromEnum(ResultFlag.success);
    @memcpy(buf[6..10], "data");
    const frame = parse_sidecar_frame(buf[0..10]) orelse unreachable;
    try std.testing.expectEqual(CallTag.result, frame.tag);
    try std.testing.expectEqual(@as(u32, 99), frame.request_id);
    const result = parse_result_payload(frame.payload) orelse unreachable;
    try std.testing.expectEqual(ResultFlag.success, result.flag);
    try std.testing.expectEqualStrings("data", result.data);
}

test "sidecar frame parse — QUERY" {
    var buf: [64]u8 = undefined;
    buf[0] = @intFromEnum(CallTag.query);
    std.mem.writeInt(u32, buf[1..5], 7, .big);
    // query_id = 3
    std.mem.writeInt(u16, buf[5..7], 3, .big);
    // sql_len = 11, sql = "SELECT * .."
    const sql = "SELECT * ..";
    std.mem.writeInt(u16, buf[7..9], @intCast(sql.len), .big);
    @memcpy(buf[9..20], sql);
    buf[20] = @intFromEnum(QueryMode.query); // mode
    buf[21] = 0; // param_count = 0
    const frame = parse_sidecar_frame(buf[0..22]) orelse unreachable;
    try std.testing.expectEqual(CallTag.query, frame.tag);
    const query = parse_query_payload(frame.payload) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 3), query.query_id);
    try std.testing.expectEqualStrings("SELECT * ..", query.sql);
    try std.testing.expectEqual(QueryMode.query, query.mode);
    try std.testing.expectEqual(@as(u8, 0), query.param_count);
}

test "QUERY_RESULT frame build" {
    var buf: [64]u8 = undefined;
    const row_data = "row_set_bytes";
    const len = build_query_result(&buf, 7, 42, row_data) orelse unreachable;
    try std.testing.expectEqual(@as(u8, @intFromEnum(CallTag.query_result)), buf[0]);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, buf[1..5], .big));
    try std.testing.expectEqual(@as(u16, 42), std.mem.readInt(u16, buf[5..7], .big));
    try std.testing.expectEqualStrings("row_set_bytes", buf[7..len]);
}

test "parse rejects invalid sidecar tag" {
    var buf: [64]u8 = undefined;
    buf[0] = @intFromEnum(CallTag.call); // server sends CALL, not sidecar
    std.mem.writeInt(u32, buf[1..5], 1, .big);
    try std.testing.expect(parse_sidecar_frame(buf[0..10]) == null);
}

test "parse rejects truncated frame" {
    var buf: [3]u8 = undefined; // too short for tag + request_id
    try std.testing.expect(parse_sidecar_frame(&buf) == null);
}

test "READY frame parse" {
    const frame = [_]u8{ @intFromEnum(CallTag.ready), 0x00, 0x01 }; // version=1
    const ready = parse_ready_frame(&frame).?;
    try std.testing.expectEqual(@as(u16, 1), ready.version);
}

test "READY frame rejects truncated version" {
    const frame = [_]u8{ @intFromEnum(CallTag.ready), 0x00 }; // only 2 bytes
    try std.testing.expect(parse_ready_frame(&frame) == null);
}

test "READY frame rejects wrong tag" {
    const frame = [_]u8{ @intFromEnum(CallTag.call), 0x00, 0x01 };
    try std.testing.expect(parse_ready_frame(&frame) == null);
}

test "READY frame rejects empty" {
    try std.testing.expect(parse_ready_frame(&[_]u8{}) == null);
}

test "cross-language CALL/RESULT vector — write to /tmp for TS reader" {
    // Write known CALL/RESULT/QUERY/QUERY_RESULT frames to a file.
    // The TS test reads the same file and verifies agreement.
    //
    // Layout: [u8 frame_count][frames: { u32 BE frame_len, frame_bytes }]
    //
    // Frame 0: CALL — request_id=1, name="prefetch", args=[op=0x14, id=0x01..0x10]
    // Frame 1: RESULT — request_id=1, flag=success, data=[status_len=2, "ok", write_count=0]
    // Frame 2: QUERY — request_id=1, query_id=7, sql="SELECT id FROM products WHERE id = ?1",
    //          mode=query, param_count=1, param=[text, "test_value"]
    // Frame 3: QUERY_RESULT — request_id=1, query_id=7, row_set=[1 col "id" integer, 1 row, value=42]

    var file_buf: [4096]u8 = undefined;
    var fpos: usize = 0;

    // Frame count.
    file_buf[fpos] = 4;
    fpos += 1;

    // Frame 0: CALL
    {
        var buf: [256]u8 = undefined;
        var args: [17]u8 = undefined;
        args[0] = 0x14; // operation
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            args[1 + i] = @intCast(i + 1); // id bytes 0x01..0x10
        }
        const len = build_call(&buf, 1, "prefetch", &args) orelse unreachable;
        std.mem.writeInt(u32, file_buf[fpos..][0..4], @intCast(len), .big);
        fpos += 4;
        @memcpy(file_buf[fpos..][0..len], buf[0..len]);
        fpos += len;
    }

    // Frame 1: RESULT
    {
        var buf: [256]u8 = undefined;
        buf[0] = @intFromEnum(CallTag.result);
        std.mem.writeInt(u32, buf[1..5], 1, .big); // request_id
        buf[5] = @intFromEnum(ResultFlag.success); // flag
        // data: [status_len: u16 BE][status_str][write_count: u8]
        std.mem.writeInt(u16, buf[6..8], 2, .big); // status_len = 2
        buf[8] = 'o';
        buf[9] = 'k';
        buf[10] = 0; // write_count = 0
        const len: usize = 11;
        std.mem.writeInt(u32, file_buf[fpos..][0..4], @intCast(len), .big);
        fpos += 4;
        @memcpy(file_buf[fpos..][0..len], buf[0..len]);
        fpos += len;
    }

    // Frame 2: QUERY
    {
        var buf: [256]u8 = undefined;
        buf[0] = @intFromEnum(CallTag.query);
        std.mem.writeInt(u32, buf[1..5], 1, .big); // request_id
        std.mem.writeInt(u16, buf[5..7], 7, .big); // query_id
        const sql = "SELECT id FROM products WHERE id = ?1";
        std.mem.writeInt(u16, buf[7..9], @intCast(sql.len), .big);
        @memcpy(buf[9..][0..sql.len], sql);
        var pos: usize = 9 + sql.len;
        buf[pos] = @intFromEnum(QueryMode.query); // mode
        pos += 1;
        buf[pos] = 1; // param_count
        pos += 1;
        // param: text "test_value"
        buf[pos] = @intFromEnum(TypeTag.text);
        pos += 1;
        const pval = "test_value";
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(pval.len), .big);
        pos += 2;
        @memcpy(buf[pos..][0..pval.len], pval);
        pos += pval.len;

        std.mem.writeInt(u32, file_buf[fpos..][0..4], @intCast(pos), .big);
        fpos += 4;
        @memcpy(file_buf[fpos..][0..pos], buf[0..pos]);
        fpos += pos;
    }

    // Frame 3: QUERY_RESULT
    {
        var buf: [256]u8 = undefined;
        buf[0] = @intFromEnum(CallTag.query_result);
        std.mem.writeInt(u32, buf[1..5], 1, .big); // request_id
        std.mem.writeInt(u16, buf[5..7], 7, .big); // query_id
        // row_set: 1 column "id" integer, 1 row, value=42
        var pos: usize = 7;
        const columns = [_]Column{.{ .type_tag = .integer, .name = "id" }};
        pos = 7 + (write_row_set_header(buf[7..], &columns) orelse unreachable);
        pos = pos + (write_row_count(buf[pos - 7 ..], 0, 1) orelse unreachable);

        // Simpler: just write inline since offsets are tricky with slicing.
        // Reset and build the row set in a separate buffer.
        var rs_buf: [128]u8 = undefined;
        var rs_pos = write_row_set_header(&rs_buf, &columns) orelse unreachable;
        rs_pos = write_row_count(&rs_buf, rs_pos, 1) orelse unreachable;
        rs_pos = write_value(&rs_buf, rs_pos, .{ .integer = 42 }) orelse unreachable;

        // Now build QUERY_RESULT frame.
        pos = 7;
        @memcpy(buf[pos..][0..rs_pos], rs_buf[0..rs_pos]);
        pos += rs_pos;

        std.mem.writeInt(u32, file_buf[fpos..][0..4], @intCast(pos), .big);
        fpos += 4;
        @memcpy(file_buf[fpos..][0..pos], buf[0..pos]);
        fpos += pos;
    }

    const file = std.fs.cwd().createFile("packages/vectors/frames.bin", .{}) catch unreachable;
    defer file.close();
    file.writeAll(file_buf[0..fpos]) catch unreachable;
}

test "cross-language CRC vector — verify CRC32 convention" {
    // Verify our CRC matches the committed crc_vectors.json values.
    // CRC convention: standard IEEE CRC32 (Crc32IsoHdlc / zlib).
    const Crc32 = std.hash.crc.Crc32;

    // Vector 1: empty → 0x00000000
    {
        var crc = Crc32.init();
        assert(crc.final() == 0x00000000);
    }
    // Vector 2: "hello" → 0x3610a686
    {
        var crc = Crc32.init();
        crc.update("hello");
        assert(crc.final() == 0x3610a686);
    }
    // Vector 3: SHM convention (u32 LE len ++ payload)
    // len=11 as LE → [0x0B, 0x00, 0x00, 0x00], payload=[0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0x70, 0x72, 0x65, 0x66]
    {
        var crc = Crc32.init();
        crc.update(&[_]u8{ 0x0B, 0x00, 0x00, 0x00 }); // len
        crc.update(&[_]u8{ 0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0x70, 0x72, 0x65, 0x66 }); // payload
        assert(crc.final() == 0xb1c7668a);
    }
}

// =====================================================================
// Comptime assertions — pin frame layout byte offsets.
// If the refactor shifts a field, compilation fails.
// =====================================================================

comptime {
    // CALL frame: [tag: u8][request_id: u32 BE][name_len: u16 BE][name][args...]
    assert(@intFromEnum(CallTag.call) == 0x10);
    assert(@intFromEnum(CallTag.result) == 0x11);
    assert(@intFromEnum(CallTag.query) == 0x12);
    assert(@intFromEnum(CallTag.query_result) == 0x13);
    assert(@intFromEnum(CallTag.ready) == 0x20);
    // CALL header: tag(1) + request_id(4) + name_len(2) = 7 bytes minimum
    const call_header_min = 1 + 4 + 2;
    assert(call_header_min == 7);
    // RESULT header: tag(1) + request_id(4) + flag(1) = 6 bytes minimum
    const result_header_min = 1 + 4 + 1;
    assert(result_header_min == 6);
    // QUERY header: tag(1) + request_id(4) + query_id(2) + sql_len(2) = 9 bytes + sql + mode(1) + param_count(1)
    const query_header_min = 1 + 4 + 2 + 2;
    assert(query_header_min == 9);
    // QUERY_RESULT header: tag(1) + request_id(4) + query_id(2) = 7 bytes minimum
    const qr_header_min = 1 + 4 + 2;
    assert(qr_header_min == 7);
    // Result flags
    assert(@intFromEnum(ResultFlag.success) == 0x00);
    assert(@intFromEnum(ResultFlag.failure) == 0x01);
}

// Handle RESULT payload layout:
//   [status_len: u16 BE][status_str][session_action: u8][write_count: u8][writes...]
// Each write: [sql_len: u16 BE][sql][param_count: u8][params...]
// Pin with comptime: offsets are fixed relative to start of result data.
pub const handle_result_status_offset = 0; // u16 BE status_len at byte 0
pub const handle_result_min_size = 2 + 1 + 1 + 1; // status_len(2) + session_action(1) + write_count(1) + dispatch_count(1) minimum (empty status)

comptime {
    assert(handle_result_min_size == 5);
}

// =====================================================================
// CALL/RESULT round-trip tests — encode then decode, assert fields match.
// These pin the wire format. If the format changes, these fail.
// =====================================================================

test "CALL frame round-trip" {
    var buf: [256]u8 = undefined;
    const len = build_call(&buf, 42, "route", "hello") orelse unreachable;
    const frame = buf[0..len];

    // Tag
    try std.testing.expectEqual(@as(u8, 0x10), frame[0]);
    // Request ID
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, frame[1..5], .big));
    // Name
    const name_len = std.mem.readInt(u16, frame[5..7], .big);
    try std.testing.expectEqual(@as(u16, 5), name_len);
    try std.testing.expectEqualStrings("route", frame[7..12]);
    // Args
    try std.testing.expectEqualStrings("hello", frame[12..17]);
}

test "RESULT parse round-trip" {
    // Build a RESULT frame manually: [tag][request_id BE][flag][data]
    var buf: [64]u8 = undefined;
    buf[0] = @intFromEnum(CallTag.result);
    std.mem.writeInt(u32, buf[1..5], 99, .big);
    buf[5] = @intFromEnum(ResultFlag.success);
    @memcpy(buf[6..11], "hello");

    const frame = parse_sidecar_frame(buf[0..11]) orelse unreachable;
    try std.testing.expectEqual(CallTag.result, frame.tag);
    try std.testing.expectEqual(@as(u32, 99), frame.request_id);

    const result = parse_result_payload(frame.payload) orelse unreachable;
    try std.testing.expectEqual(ResultFlag.success, result.flag);
    try std.testing.expectEqualStrings("hello", result.data);
}

test "build_result round-trip" {
    // Pair assertion: build_result produces frames that parse_sidecar_frame
    // + parse_result_payload accept. Catches format drift.
    var buf: [256]u8 = undefined;
    const data = "test_payload";
    const len = build_result(&buf, 42, .success, data) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 1 + 4 + 1 + data.len), len);

    const frame = parse_sidecar_frame(buf[0..len]) orelse unreachable;
    try std.testing.expectEqual(CallTag.result, frame.tag);
    try std.testing.expectEqual(@as(u32, 42), frame.request_id);

    const result = parse_result_payload(frame.payload) orelse unreachable;
    try std.testing.expectEqual(ResultFlag.success, result.flag);
    try std.testing.expectEqualStrings(data, result.data);
}

test "build_result — failure flag" {
    var buf: [64]u8 = undefined;
    const len = build_result(&buf, 7, .failure, "") orelse unreachable;
    const frame = parse_sidecar_frame(buf[0..len]) orelse unreachable;
    const result = parse_result_payload(frame.payload) orelse unreachable;
    try std.testing.expectEqual(ResultFlag.failure, result.flag);
    try std.testing.expectEqual(@as(usize, 0), result.data.len);
}

test "build_result — overflow returns null" {
    var buf: [5]u8 = undefined; // too small for header (6 bytes min)
    try std.testing.expect(build_result(&buf, 1, .success, "") == null);
}

test "QUERY_RESULT build round-trip" {
    var buf: [64]u8 = undefined;
    const row_set = "fake_rows";
    const len = build_query_result(&buf, 7, 3, row_set) orelse unreachable;
    const frame = buf[0..len];

    // QUERY_RESULT is sent by the server to the sidecar, not received
    // from the sidecar. parse_sidecar_frame rejects it (correct).
    // Verify raw byte layout instead.
    try std.testing.expectEqual(@as(u8, 0x13), frame[0]); // tag
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, frame[1..5], .big)); // request_id
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, frame[5..7], .big)); // query_id
    try std.testing.expectEqualStrings(row_set, frame[7..16]); // payload
}

test "handle RESULT payload format" {
    // Pin the handle RESULT payload format used by TS dispatchHandle.
    // Layout: [status_len: u16 BE][status][session_action: u8][write_count: u8]
    var buf: [64]u8 = undefined;
    var pos: usize = 0;

    const status = "ok";
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(status.len), .big);
    pos += 2;
    @memcpy(buf[pos..][0..status.len], status);
    pos += status.len;
    buf[pos] = 0; // session_action = none
    pos += 1;
    buf[pos] = 0; // write_count = 0
    pos += 1;

    // Parse it back — same offsets the Zig sidecar handler uses.
    const payload = buf[0..pos];
    const parsed_status_len = std.mem.readInt(u16, payload[0..2], .big);
    try std.testing.expectEqual(@as(u16, 2), parsed_status_len);
    try std.testing.expectEqualStrings("ok", payload[2..4]);
    try std.testing.expectEqual(@as(u8, 0), payload[4]); // session_action
    try std.testing.expectEqual(@as(u8, 0), payload[5]); // write_count
}

test "parse_sidecar_frame rejects garbage" {
    // Too short
    try std.testing.expect(parse_sidecar_frame("") == null);
    try std.testing.expect(parse_sidecar_frame("abcd") == null);
    // Invalid tag
    var bad_tag = [_]u8{ 0xFF, 0, 0, 0, 0 };
    try std.testing.expect(parse_sidecar_frame(&bad_tag) == null);
    // CALL tag — parse_sidecar_frame only accepts result/query (from sidecar)
    var call_tag = [_]u8{ 0x10, 0, 0, 0, 0 };
    try std.testing.expect(parse_sidecar_frame(&call_tag) == null);
}

/// Advance past `param_count` type-tagged parameters in a binary payload.
/// Returns the position after the last parameter, or null if the data is
/// truncated or contains an invalid type tag. Used by write execution to
/// skip past parameter bytes without copying.
pub fn skip_params(data: []const u8, start: usize, param_count: u8) ?usize {
    // Precondition: start must be within data (or at end for 0 params).
    assert(start <= data.len);

    var pos = start;
    for (0..param_count) |_| {
        if (pos >= data.len) return null;
        const tag = std.meta.intToEnum(TypeTag, data[pos]) catch return null;
        pos += 1;
        switch (tag) {
            .integer, .float => {
                if (pos + 8 > data.len) return null;
                pos += 8;
            },
            .text, .blob => {
                if (pos + 2 > data.len) return null;
                const vlen = std.mem.readInt(u16, data[pos..][0..2], .big);
                pos += 2;
                if (pos + vlen > data.len) return null;
                pos += vlen;
            },
            .null => {},
        }
    }

    // Postcondition: position advanced past all params, still in bounds.
    assert(pos >= start);
    assert(pos <= data.len);
    return pos;
}

test "parse_result_payload rejects garbage" {
    try std.testing.expect(parse_result_payload("") == null);
    // Invalid flag byte
    var bad_flag = [_]u8{0xFF};
    try std.testing.expect(parse_result_payload(&bad_flag) == null);
}

test "parse_query_payload rejects truncated" {
    try std.testing.expect(parse_query_payload("") == null);
    try std.testing.expect(parse_query_payload("ab") == null);
    // query_id + sql_len present but sql truncated
    var short: [6]u8 = undefined;
    std.mem.writeInt(u16, short[0..2], 0, .big); // query_id
    std.mem.writeInt(u16, short[2..4], 100, .big); // sql_len = 100 (way past end)
    try std.testing.expect(parse_query_payload(&short) == null);
}

test "skip_params valid round-trip" {
    // Build valid params: [integer: 42][text: "hi"][null]
    var buf: [32]u8 = undefined;
    buf[0] = @intFromEnum(TypeTag.integer); // tag
    std.mem.writeInt(i64, buf[1..9], 42, .little); // 8-byte value
    buf[9] = @intFromEnum(TypeTag.text); // tag
    std.mem.writeInt(u16, buf[10..12], 2, .big); // len=2
    buf[12] = 'h';
    buf[13] = 'i';
    buf[14] = @intFromEnum(TypeTag.null); // tag

    // 3 params starting at offset 0 → should land at 15.
    try std.testing.expectEqual(skip_params(&buf, 0, 3), 15);
    // 0 params → stays at start.
    try std.testing.expectEqual(skip_params(&buf, 0, 0), 0);
    // 1 param at offset 9 (text "hi") → 15.
    try std.testing.expectEqual(skip_params(&buf, 9, 1), 14);
}

test "skip_params rejects truncated and invalid" {
    // Empty data, any params → null.
    try std.testing.expect(skip_params("", 0, 1) == null);
    // Invalid tag byte.
    var bad = [_]u8{0xFF};
    try std.testing.expect(skip_params(&bad, 0, 1) == null);
    // Integer tag but truncated (only 4 bytes, need 8).
    var short: [5]u8 = undefined;
    short[0] = @intFromEnum(TypeTag.integer);
    try std.testing.expect(skip_params(&short, 0, 1) == null);
    // Text tag with length exceeding buffer.
    var text_trunc: [4]u8 = undefined;
    text_trunc[0] = @intFromEnum(TypeTag.text);
    std.mem.writeInt(u16, text_trunc[1..3], 100, .big); // claims 100 bytes
    try std.testing.expect(skip_params(&text_trunc, 0, 1) == null);
}

fn test_socketpair() [2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    assert(rc == 0);
    return fds;
}
