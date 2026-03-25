const std = @import("std");
const assert = std.debug.assert;
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
// Route pattern matching
// =====================================================================

/// Maximum route params (e.g. /orders/:id/items/:item_id = 2 params).
const max_route_params = 4;

/// Extracted route parameters — string slices into the original path.
pub const RouteParams = struct {
    keys: [max_route_params][]const u8 = .{&.{}} ** max_route_params,
    values: [max_route_params][]const u8 = .{&.{}} ** max_route_params,
    len: u8 = 0,

    /// Get a param value by name. Returns null if not found.
    pub fn get(self: *const RouteParams, name: []const u8) ?[]const u8 {
        for (self.keys[0..self.len], self.values[0..self.len]) |k, v| {
            if (std.mem.eql(u8, k, name)) return v;
        }
        return null;
    }
};

/// Count :param segments in a route pattern at comptime.
fn count_params(comptime pattern: []const u8) comptime_int {
    var count: comptime_int = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == ':') count += 1;
    }
    return count;
}

/// Match a URL path against a route pattern. Returns extracted params
/// or null if the path doesn't match. Pattern segments are literal
/// strings or `:name` params. The path must have the same number of
/// segments as the pattern.
///
/// Example: match_route("/products/abc123", "/products/:id")
///   → RouteParams with id = "abc123"
///
/// The path must start with /. Leading slash is stripped before matching.
pub fn match_route(path: []const u8, comptime pattern: []const u8) ?RouteParams {
    comptime {
        assert(pattern.len > 0 and pattern[0] == '/'); // pattern must start with /
        assert(count_params(pattern) <= max_route_params); // pattern fits RouteParams
    }
    if (path.len == 0 or path[0] != '/') return null;

    // Root pattern matches root path.
    if (comptime std.mem.eql(u8, pattern, "/")) {
        return if (path.len == 1) RouteParams{} else null;
    }

    // Strip leading slash from both — then split on /.
    const path_rest = path[1..];
    comptime var pat_rest: []const u8 = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;

    var params = RouteParams{};

    // Walk pattern segments at comptime, match against path at runtime.
    comptime var seg_index: u32 = 0;
    var path_pos: usize = 0;

    inline while (true) {
        // Find next pattern segment.
        const pat_slash = comptime std.mem.indexOf(u8, pat_rest, "/");
        const pat_seg = comptime if (pat_slash) |s| pat_rest[0..s] else pat_rest;
        comptime {
            pat_rest = if (pat_slash) |s| pat_rest[s + 1 ..] else "";
        }

        // Find next path segment.
        if (path_pos > path_rest.len) return null;
        const path_remaining = path_rest[path_pos..];
        const path_slash = std.mem.indexOfScalar(u8, path_remaining, '/');
        const path_seg = if (path_slash) |s| path_remaining[0..s] else path_remaining;

        // Empty path segment = path is shorter than pattern.
        if (path_seg.len == 0 and pat_seg.len > 0) return null;

        if (comptime pat_seg.len > 0 and pat_seg[0] == ':') {
            // Param segment — extract value.
            if (path_seg.len == 0) return null;
            params.keys[params.len] = comptime pat_seg[1..];
            params.values[params.len] = path_seg;
            params.len += 1;
        } else {
            // Literal segment — must match exactly.
            if (!std.mem.eql(u8, path_seg, comptime pat_seg)) return null;
        }

        path_pos += path_seg.len + 1; // +1 for the slash
        seg_index += 1;

        // End of pattern?
        if (comptime pat_rest.len == 0) {
            // Path must also be at the end — no extra segments.
            if (path_slash != null) return null;
            return params;
        }
    }
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

// --- match_route tests ---

test "match_route: root" {
    const r = match_route("/", "/").?;
    try std.testing.expectEqual(@as(u8, 0), r.len);
}

test "match_route: root rejects non-root" {
    try std.testing.expect(match_route("/products", "/") == null);
}

test "match_route: literal path" {
    const r = match_route("/products", "/products").?;
    try std.testing.expectEqual(@as(u8, 0), r.len);
}

test "match_route: literal rejects wrong segment" {
    try std.testing.expect(match_route("/orders", "/products") == null);
}

test "match_route: single param" {
    const r = match_route("/products/abc123", "/products/:id").?;
    try std.testing.expectEqual(@as(u8, 1), r.len);
    try std.testing.expectEqualSlices(u8, r.get("id").?, "abc123");
}

test "match_route: two params" {
    const r = match_route("/products/abc/transfer_inventory/def", "/products/:id/transfer_inventory/:sub_id").?;
    try std.testing.expectEqual(@as(u8, 2), r.len);
    try std.testing.expectEqualSlices(u8, r.get("id").?, "abc");
    try std.testing.expectEqualSlices(u8, r.get("sub_id").?, "def");
}

test "match_route: sub-resource" {
    const r = match_route("/orders/abc123/complete", "/orders/:id/complete").?;
    try std.testing.expectEqualSlices(u8, r.get("id").?, "abc123");
}

test "match_route: rejects extra segments" {
    try std.testing.expect(match_route("/products/abc/extra", "/products/:id") == null);
}

test "match_route: rejects too few segments" {
    try std.testing.expect(match_route("/products", "/products/:id") == null);
}

test "match_route: rejects empty path" {
    try std.testing.expect(match_route("", "/products") == null);
}

test "match_route: multi-segment literal" {
    const r = match_route("/login/verify", "/login/verify").?;
    try std.testing.expectEqual(@as(u8, 0), r.len);
}

test "match_route: login code" {
    const r = match_route("/login/code", "/login/code").?;
    try std.testing.expectEqual(@as(u8, 0), r.len);
}

test "match_route: inventory sub-resource" {
    const r = match_route("/products/abc123/inventory", "/products/:id/inventory").?;
    try std.testing.expectEqualSlices(u8, r.get("id").?, "abc123");
}
