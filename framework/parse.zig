const std = @import("std");
const stdx = @import("stdx.zig");

// =====================================================================
// JSON field extractors — find known fields in a JSON object.
// Hand-rolled, no allocations, no std.json.
// =====================================================================

/// Find a string field: "field_name":"value"
/// Returns the unescaped value or null if not found.
/// Does NOT handle escaped quotes inside values.
pub fn json_string_field(json: []const u8, field: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < json.len) {
        const q = std.mem.indexOf(u8, json[pos..], "\"") orelse return null;
        const abs_q = pos + q;

        if (abs_q + 1 + field.len + 3 > json.len) {
            pos = abs_q + 1;
            continue;
        }

        if (std.mem.eql(u8, json[abs_q + 1 ..][0..field.len], field)) {
            const after_field = abs_q + 1 + field.len;
            if (after_field + 3 <= json.len and std.mem.eql(u8, json[after_field..][0..3], "\":\"")) {
                const val_start = after_field + 3;
                const val_end = std.mem.indexOf(u8, json[val_start..], "\"") orelse return null;
                return json[val_start..][0..val_end];
            }
        }
        pos = abs_q + 1;
    }
    return null;
}

/// Find a numeric field: "field_name":12345
pub fn json_u32_field(json: []const u8, field: []const u8) ?u32 {
    var pos: usize = 0;
    while (pos < json.len) {
        const q = std.mem.indexOf(u8, json[pos..], "\"") orelse return null;
        const abs_q = pos + q;

        if (abs_q + 1 + field.len + 2 > json.len) {
            pos = abs_q + 1;
            continue;
        }

        if (std.mem.eql(u8, json[abs_q + 1 ..][0..field.len], field)) {
            const after_field = abs_q + 1 + field.len;
            if (after_field + 2 <= json.len and std.mem.eql(u8, json[after_field..][0..2], "\":")) {
                const val_start = after_field + 2;
                var end = val_start;
                while (end < json.len and json[end] >= '0' and json[end] <= '9') {
                    end += 1;
                }
                if (end == val_start) return null;
                return std.fmt.parseInt(u32, json[val_start..end], 10) catch return null;
            }
        }
        pos = abs_q + 1;
    }
    return null;
}

/// Find a boolean field: "field_name":true or "field_name":false
pub fn json_bool_field(json: []const u8, field: []const u8) ?bool {
    var pos: usize = 0;
    while (pos < json.len) {
        const q = std.mem.indexOf(u8, json[pos..], "\"") orelse return null;
        const abs_q = pos + q;

        if (abs_q + 1 + field.len + 2 > json.len) {
            pos = abs_q + 1;
            continue;
        }

        if (std.mem.eql(u8, json[abs_q + 1 ..][0..field.len], field)) {
            const after_field = abs_q + 1 + field.len;
            if (after_field + 2 <= json.len and std.mem.eql(u8, json[after_field..][0..2], "\":")) {
                const val_start = after_field + 2;
                if (val_start + 4 <= json.len and std.mem.eql(u8, json[val_start..][0..4], "true")) return true;
                if (val_start + 5 <= json.len and std.mem.eql(u8, json[val_start..][0..5], "false")) return false;
                return null;
            }
        }
        pos = abs_q + 1;
    }
    return null;
}

// =====================================================================
// Query string parsing
// =====================================================================

/// Extract the value of a query parameter by key. Returns null if not found.
pub fn query_param(query: []const u8, key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < query.len) {
        if (query[pos] == '&') {
            pos += 1;
            continue;
        }
        const rest = query[pos..];
        if (rest.len > key.len and std.mem.startsWith(u8, rest, key) and rest[key.len] == '=') {
            const value_start = pos + key.len + 1;
            const value_end = std.mem.indexOf(u8, query[value_start..], "&") orelse query.len - value_start;
            return query[value_start..][0..value_end];
        }
        pos = if (std.mem.indexOfPos(u8, query, pos, "&")) |amp| amp + 1 else query.len;
    }
    return null;
}

/// Parse a decimal string as u32. Returns 0 on invalid input.
pub fn parse_query_u32(s: []const u8) u32 {
    if (s.len == 0 or s.len > 10) return 0;
    var result: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return 0;
        result = std.math.mul(u32, result, 10) catch return 0;
        result = std.math.add(u32, result, c - '0') catch return 0;
    }
    return result;
}

// =====================================================================
// REST path parsing
// =====================================================================

pub const PathSegments = struct {
    collection: []const u8,
    id: u128,
    has_id: bool,
    sub_resource: []const u8,
    sub_id: u128,
    has_sub_id: bool,
};

/// Split a REST path into up to 4 segments: /resource/:id/sub/:sub_id
/// Returns null if any UUID segment is present but fails to parse.
pub fn split_path(path: []const u8) ?PathSegments {
    const s1 = std.mem.indexOf(u8, path, "/");
    const collection = if (s1) |s| path[0..s] else path;
    const rest1 = if (s1) |s| path[s + 1 ..] else "";

    const s2 = if (rest1.len > 0) std.mem.indexOf(u8, rest1, "/") else null;
    const id_str = if (s2) |s| rest1[0..s] else rest1;
    const rest2 = if (s2) |s| rest1[s + 1 ..] else "";

    const s3 = if (rest2.len > 0) std.mem.indexOf(u8, rest2, "/") else null;
    const sub_resource = if (s3) |s| rest2[0..s] else rest2;
    const rest3 = if (s3) |s| rest2[s + 1 ..] else "";

    const sub_id_str = rest3;

    const id: u128 = if (id_str.len > 0) stdx.parse_uuid(id_str) orelse return null else 0;
    const sub_id: u128 = if (sub_id_str.len > 0) stdx.parse_uuid(sub_id_str) orelse return null else 0;

    return .{
        .collection = collection,
        .id = id,
        .has_id = id_str.len > 0,
        .sub_resource = sub_resource,
        .sub_id = sub_id,
        .has_sub_id = sub_id_str.len > 0,
    };
}

// =====================================================================
// Tests
// =====================================================================

test "json_string_field extracts value" {
    const json =
        \\{"name":"hello","other":"world"}
    ;
    const val = json_string_field(json, "name").?;
    try std.testing.expectEqualSlices(u8, val, "hello");
    const other = json_string_field(json, "other").?;
    try std.testing.expectEqualSlices(u8, other, "world");
}

test "json_u32_field extracts number" {
    const json =
        \\{"price_cents":1999,"inventory":42}
    ;
    try std.testing.expectEqual(json_u32_field(json, "price_cents").?, 1999);
    try std.testing.expectEqual(json_u32_field(json, "inventory").?, 42);
}

test "json_bool_field extracts boolean" {
    try std.testing.expectEqual(json_bool_field(
        \\{"active":true}
    , "active").?, true);
    try std.testing.expectEqual(json_bool_field(
        \\{"active":false}
    , "active").?, false);
}

test "query_param extracts values" {
    try std.testing.expectEqualSlices(u8, query_param("foo=bar&baz=qux", "foo").?, "bar");
    try std.testing.expectEqualSlices(u8, query_param("foo=bar&baz=qux", "baz").?, "qux");
    try std.testing.expect(query_param("foo=bar", "missing") == null);
}

test "split_path parses REST segments" {
    const seg = split_path("products").?;
    try std.testing.expectEqualSlices(u8, seg.collection, "products");
    try std.testing.expect(!seg.has_id);

    const seg2 = split_path("products/00000000000000000000000000000001").?;
    try std.testing.expectEqual(seg2.id, 1);
    try std.testing.expect(seg2.has_id);

    try std.testing.expect(split_path("products/invalid") == null);
}
