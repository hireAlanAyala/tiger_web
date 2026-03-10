const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const http = @import("http.zig");

/// Translate an HTTP method + path + body into a typed Message.
/// Path format: /resource or /resource/:id or /resource/:id/sub/:sub_id
/// Returns null if the request doesn't map to a valid operation.
pub fn translate(method: http.Method, raw_path: []const u8, body: []const u8) ?message.Message {
    // Strip leading /.
    const path = if (raw_path.len > 0 and raw_path[0] == '/') raw_path[1..] else raw_path;
    if (path.len == 0) return null;

    // Split path from query string.
    const query_sep = std.mem.indexOf(u8, path, "?");
    const path_clean = if (query_sep) |q| path[0..q] else path;
    const query_string = if (query_sep) |q| path[q + 1 ..] else "";

    // Parse pagination cursor from ?after=<uuid>.
    const cursor = parse_query_cursor(query_string);

    // Split path into up to 4 segments: /resource/:id/sub/:sub_id
    const segments = split_path(path_clean) orelse return null;

    if (method == .options) return null;

    // Match resource and resolve to flat operation.
    return if (std.mem.eql(u8, segments.collection, "products"))
        translate_products(method, segments, body, cursor)
    else if (std.mem.eql(u8, segments.collection, "collections"))
        translate_collections(method, segments, body, cursor)
    else if (std.mem.eql(u8, segments.collection, "orders"))
        translate_orders(method, segments, body, cursor)
    else
        null;
}

const PathSegments = struct {
    collection: []const u8,
    id: u128,
    has_id: bool,
    sub_resource: []const u8,
    sub_id: u128,
    has_sub_id: bool,
};

/// Split a path into up to 4 segments. Returns null if any UUID segment
/// is present but fails to parse.
fn split_path(path: []const u8) ?PathSegments {
    // Segment 1: collection name.
    const s1 = std.mem.indexOf(u8, path, "/");
    const collection = if (s1) |s| path[0..s] else path;
    const rest1 = if (s1) |s| path[s + 1 ..] else "";

    // Segment 2: primary ID.
    const s2 = if (rest1.len > 0) std.mem.indexOf(u8, rest1, "/") else null;
    const id_str = if (s2) |s| rest1[0..s] else rest1;
    const rest2 = if (s2) |s| rest1[s + 1 ..] else "";

    // Segment 3: sub-resource name.
    const s3 = if (rest2.len > 0) std.mem.indexOf(u8, rest2, "/") else null;
    const sub_resource = if (s3) |s| rest2[0..s] else rest2;
    const rest3 = if (s3) |s| rest2[s + 1 ..] else "";

    // Segment 4: sub-resource ID.
    const sub_id_str = rest3;

    // Parse UUIDs — return null on malformed.
    const id: u128 = if (id_str.len > 0) parse_uuid(id_str) orelse return null else 0;
    const sub_id: u128 = if (sub_id_str.len > 0) parse_uuid(sub_id_str) orelse return null else 0;

    return .{
        .collection = collection,
        .id = id,
        .has_id = id_str.len > 0,
        .sub_resource = sub_resource,
        .sub_id = sub_id,
        .has_sub_id = sub_id_str.len > 0,
    };
}

fn translate_products(method: http.Method, seg: PathSegments, body: []const u8, cursor: u128) ?message.Message {
    // POST /products/:id/transfer-inventory/:target_id — uses sub_id for target.
    if (seg.has_id and seg.sub_resource.len > 0 and method == .post) {
        if (std.mem.eql(u8, seg.sub_resource, "transfer-inventory") and seg.has_sub_id) {
            if (body.len == 0) return null;
            const quantity = json_u32_field(body, "quantity") orelse return null;
            if (quantity == 0) return null;
            if (seg.id == seg.sub_id) return null;
            return .{
                .operation = .transfer_inventory,
                .id = seg.id,
                .event = .{ .transfer = .{
                    .target_id = seg.sub_id,
                    .quantity = quantity,
                } },
            };
        }
        return null;
    }

    const operation: message.Operation = switch (method) {
        .get => blk: {
            if (seg.has_id and seg.sub_resource.len > 0) {
                if (std.mem.eql(u8, seg.sub_resource, "inventory")) break :blk .get_product_inventory;
                return null;
            }
            break :blk if (seg.has_id) .get_product else .list_products;
        },
        .post => if (!seg.has_id) .create_product else return null,
        .put => if (seg.has_id) .update_product else return null,
        .delete => if (seg.has_id) .delete_product else return null,
        .options => return null,
    };

    switch (operation) {
        .list_products => {
            if (body.len != 0) return null;
            return .{ .operation = operation, .id = 0, .event = .{ .list = .{ .cursor = cursor } } };
        },
        .get_product, .delete_product, .get_product_inventory => {
            if (body.len != 0) return null;
            return .{ .operation = operation, .id = seg.id, .event = .{ .none = {} } };
        },
        .create_product, .update_product => {
            if (body.len == 0) return null;
            return .{
                .operation = operation,
                .id = seg.id,
                .event = .{ .product = parse_product_json(body) orelse return null },
            };
        },
        else => return null,
    }
}

fn translate_collections(method: http.Method, seg: PathSegments, body: []const u8, cursor: u128) ?message.Message {
    // /collections/:id/products/:product_id — membership operations.
    if (seg.has_id and seg.sub_resource.len > 0) {
        if (!std.mem.eql(u8, seg.sub_resource, "products")) return null;
        if (!seg.has_sub_id) return null;

        const operation: message.Operation = switch (method) {
            .post => .add_collection_member,
            .delete => .remove_collection_member,
            else => return null,
        };

        if (body.len != 0) return null;
        return .{
            .operation = operation,
            .id = seg.id,
            .event = .{ .member_id = seg.sub_id },
        };
    }

    const operation: message.Operation = switch (method) {
        .get => if (seg.has_id) .get_collection else .list_collections,
        .post => if (!seg.has_id) .create_collection else return null,
        .delete => if (seg.has_id) .delete_collection else return null,
        else => return null,
    };

    switch (operation) {
        .list_collections => {
            if (body.len != 0) return null;
            return .{ .operation = operation, .id = 0, .event = .{ .list = .{ .cursor = cursor } } };
        },
        .get_collection, .delete_collection => {
            if (body.len != 0) return null;
            return .{ .operation = operation, .id = seg.id, .event = .{ .none = {} } };
        },
        .create_collection => {
            if (body.len == 0) return null;
            return .{
                .operation = operation,
                .id = seg.id,
                .event = .{ .collection = parse_collection_json(body) orelse return null },
            };
        },
        else => return null,
    }
}

fn translate_orders(method: http.Method, seg: PathSegments, body: []const u8, cursor: u128) ?message.Message {
    switch (method) {
        .get => {
            if (body.len != 0) return null;
            if (seg.has_id) {
                return .{ .operation = .get_order, .id = seg.id, .event = .{ .none = {} } };
            } else {
                return .{ .operation = .list_orders, .id = 0, .event = .{ .list = .{ .cursor = cursor } } };
            }
        },
        .post => {
            if (seg.has_id) return null;
            if (body.len == 0) return null;
            const order = parse_order_json(body) orelse return null;
            return .{
                .operation = .create_order,
                .id = order.id,
                .event = .{ .order = order },
            };
        },
        else => return null,
    }
}

/// Parse a JSON body into an OrderRequest.
/// Expected format:
/// {"id":"...","items":[{"product_id":"...","quantity":N},...]}
fn parse_order_json(body: []const u8) ?message.OrderRequest {
    var order = message.OrderRequest{
        .id = 0,
        .items = undefined,
        .items_len = 0,
    };

    // ID is required.
    const id_str = json_string_field(body, "id") orelse return null;
    order.id = parse_uuid(id_str) orelse return null;
    if (order.id == 0) return null;

    // Find the items array.
    const items_start = std.mem.indexOf(u8, body, "\"items\"") orelse return null;
    const bracket_start = std.mem.indexOfPos(u8, body, items_start, "[") orelse return null;
    const bracket_end = std.mem.indexOf(u8, body[bracket_start..], "]") orelse return null;
    const items_body = body[bracket_start + 1 .. bracket_start + bracket_end];

    // Parse each item object.
    var pos: usize = 0;
    while (pos < items_body.len) {
        const obj_start = std.mem.indexOfPos(u8, items_body, pos, "{") orelse break;
        const obj_end = std.mem.indexOfPos(u8, items_body, obj_start, "}") orelse return null;
        const obj = items_body[obj_start .. obj_end + 1];

        if (order.items_len >= message.order_items_max) return null;

        const pid_str = json_string_field(obj, "product_id") orelse return null;
        const pid = parse_uuid(pid_str) orelse return null;
        if (pid == 0) return null;
        const qty = json_u32_field(obj, "quantity") orelse return null;
        if (qty == 0) return null;

        // Reject duplicate product IDs within the same order.
        for (order.items[0..order.items_len]) |existing| {
            if (existing.product_id == pid) return null;
        }

        order.items[order.items_len] = .{
            .product_id = pid,
            .quantity = qty,
        };
        order.items_len += 1;
        pos = obj_end + 1;
    }

    if (order.items_len == 0) return null;
    return order;
}

/// Parse a JSON body into a Product struct.
/// Hand-rolled parser for known fields. No std.json, no allocations.
///
/// Expected format:
/// {"name":"...","description":"...","price_cents":N,"inventory":N,"active":true/false}
///
/// All fields except name are optional for updates. Name is always required.
fn parse_product_json(body: []const u8) ?message.Product {
    var product = message.Product{
        .id = 0,
        .name = undefined,
        .name_len = 0,
        .description = undefined,
        .description_len = 0,
        .price_cents = 0,
        .inventory = 0,
        .version = 0,
        .active = true,
    };

    // ID is optional in the body (used for create).
    if (json_string_field(body, "id")) |id_str| {
        product.id = parse_uuid(id_str) orelse return null;
    }

    // Name is required.
    const name = json_string_field(body, "name") orelse return null;
    if (name.len == 0 or name.len > message.product_name_max) return null;
    @memcpy(product.name[0..name.len], name);
    product.name_len = @intCast(name.len);

    // Description is optional.
    if (json_string_field(body, "description")) |desc| {
        if (desc.len > message.product_description_max) return null;
        @memcpy(product.description[0..desc.len], desc);
        product.description_len = @intCast(desc.len);
    }

    // price_cents is optional (defaults to 0).
    if (json_u32_field(body, "price_cents")) |price| {
        product.price_cents = price;
    }

    // inventory is optional (defaults to 0).
    if (json_u32_field(body, "inventory")) |inv| {
        product.inventory = inv;
    }

    // version is optional (defaults to 0 — ignored on create, required on update).
    if (json_u32_field(body, "version")) |v| {
        product.version = v;
    }

    // active is optional (defaults to true).
    if (json_bool_field(body, "active")) |a| {
        product.active = a;
    }

    return product;
}

/// Parse a JSON body into a ProductCollection struct.
/// Expected: {"id":"...","name":"..."}
/// ID is required (client-provided). Name is required.
fn parse_collection_json(body: []const u8) ?message.ProductCollection {
    var col = message.ProductCollection{
        .id = 0,
        .name = undefined,
        .name_len = 0,
    };

    if (json_string_field(body, "id")) |id_str| {
        col.id = parse_uuid(id_str) orelse return null;
    }

    const name = json_string_field(body, "name") orelse return null;
    if (name.len == 0 or name.len > message.collection_name_max) return null;
    @memcpy(col.name[0..name.len], name);
    col.name_len = @intCast(name.len);

    return col;
}

/// Encode a MessageResponse as JSON into buf. Returns the written slice.
/// The response is self-describing — the encoder switches on the result variant.
pub fn encode_response_json(buf: []u8, resp: message.MessageResponse) []const u8 {
    var w = JsonWriter{ .buf = buf, .pos = 0 };

    switch (resp.status) {
        .not_found => {
            w.raw("{\"error\":\"not found\"}");
            return buf[0..w.pos];
        },
        .insufficient_inventory => {
            w.raw("{\"error\":\"insufficient_inventory\"}");
            return buf[0..w.pos];
        },
        .version_conflict => {
            w.raw("{\"error\":\"version_conflict\"}");
            return buf[0..w.pos];
        },
        .storage_error => {
            w.raw("{\"error\":\"service unavailable\"}");
            return buf[0..w.pos];
        },
        .ok => {},
    }

    switch (resp.result) {
        .product => |*p| encode_product(&w, p),
        .product_list => |*l| {
            w.raw("{\"data\":[");
            for (l.items[0..l.len], 0..) |*p, i| {
                if (i > 0) w.raw(",");
                encode_product(&w, p);
            }
            w.raw("]");
            write_next_cursor(&w, if (l.len > 0) l.items[l.len - 1].id else 0, l.len);
            w.raw("}");
        },
        .inventory => |inv| {
            w.raw("{\"inventory\":");
            w.write_u32(inv);
            w.raw("}");
        },
        .collection => |*cwp| {
            w.raw("{\"id\":\"");
            w.write_uuid(cwp.collection.id);
            w.raw("\",\"name\":\"");
            w.escaped(cwp.collection.name_slice());
            w.raw("\",\"products\":[");
            for (cwp.products.items[0..cwp.products.len], 0..) |*p, i| {
                if (i > 0) w.raw(",");
                encode_product(&w, p);
            }
            w.raw("]}");
        },
        .collection_list => |*l| {
            w.raw("{\"data\":[");
            for (l.items[0..l.len], 0..) |*col, i| {
                if (i > 0) w.raw(",");
                w.raw("{\"id\":\"");
                w.write_uuid(col.id);
                w.raw("\",\"name\":\"");
                w.escaped(col.name_slice());
                w.raw("\"}");
            }
            w.raw("]");
            write_next_cursor(&w, if (l.len > 0) l.items[l.len - 1].id else 0, l.len);
            w.raw("}");
        },
        .order => |*o| {
            w.raw("{\"id\":\"");
            w.write_uuid(o.id);
            w.raw("\",\"items\":[");
            for (o.items[0..o.items_len], 0..) |*item, i| {
                if (i > 0) w.raw(",");
                w.raw("{\"product_id\":\"");
                w.write_uuid(item.product_id);
                w.raw("\",\"name\":\"");
                w.escaped(item.name_slice());
                w.raw("\",\"quantity\":");
                w.write_u32(item.quantity);
                w.raw(",\"price_cents\":");
                w.write_u32(item.price_cents);
                w.raw(",\"line_total_cents\":");
                w.write_u64(item.line_total_cents);
                w.raw("}");
            }
            w.raw("],\"total_cents\":");
            w.write_u64(o.total_cents);
            w.raw("}");
        },
        .order_list => |*l| {
            w.raw("{\"data\":[");
            for (l.items[0..l.len], 0..) |*o, i| {
                if (i > 0) w.raw(",");
                w.raw("{\"id\":\"");
                w.write_uuid(o.id);
                w.raw("\",\"total_cents\":");
                w.write_u64(o.total_cents);
                w.raw(",\"items_count\":");
                w.write_u32(@intCast(o.items_len));
                w.raw("}");
            }
            w.raw("]");
            write_next_cursor(&w, if (l.len > 0) l.items[l.len - 1].id else 0, l.len);
            w.raw("}");
        },
        .empty => w.raw("[]"),
    }

    return buf[0..w.pos];
}

/// Write ,"next_cursor":"<uuid>" if the page is full, or ,"next_cursor":null otherwise.
fn write_next_cursor(w: *JsonWriter, last_id: u128, len: u32) void {
    if (len == message.list_max) {
        w.raw(",\"next_cursor\":\"");
        w.write_uuid(last_id);
        w.raw("\"");
    } else {
        w.raw(",\"next_cursor\":null");
    }
}

fn encode_product(w: *JsonWriter, p: *const message.Product) void {
    w.raw("{\"id\":\"");
    w.write_uuid(p.id);
    w.raw("\",\"name\":\"");
    w.escaped(p.name_slice());
    w.raw("\",\"description\":\"");
    w.escaped(p.description_slice());
    w.raw("\",\"price_cents\":");
    w.write_u32(p.price_cents);
    w.raw(",\"inventory\":");
    w.write_u32(p.inventory);
    w.raw(",\"version\":");
    w.write_u32(p.version);
    w.raw(",\"active\":");
    w.raw(if (p.active) "true" else "false");
    w.raw("}");
}

// =====================================================================
// JSON writer — writes directly into a fixed buffer, no allocations
// =====================================================================

const JsonWriter = struct {
    buf: []u8,
    pos: usize,

    fn raw(self: *JsonWriter, s: []const u8) void {
        assert(self.pos + s.len <= self.buf.len);
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }

    fn write_u32(self: *JsonWriter, val: u32) void {
        var num_buf: [10]u8 = undefined;
        const s = format_u32(&num_buf, val);
        self.raw(s);
    }

    fn write_u64(self: *JsonWriter, val: u64) void {
        var num_buf: [20]u8 = undefined;
        const s = format_u64(&num_buf, val);
        self.raw(s);
    }

    fn write_uuid(self: *JsonWriter, val: u128) void {
        var uuid_buf: [32]u8 = undefined;
        write_uuid_to_buf(&uuid_buf, val);
        self.raw(&uuid_buf);
    }

    /// Write a string with JSON escaping (quotes and backslashes).
    fn escaped(self: *JsonWriter, s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '"' => self.raw("\\\""),
                '\\' => self.raw("\\\\"),
                '\n' => self.raw("\\n"),
                '\r' => self.raw("\\r"),
                '\t' => self.raw("\\t"),
                else => {
                    assert(self.pos < self.buf.len);
                    self.buf[self.pos] = c;
                    self.pos += 1;
                },
            }
        }
    }
};

// =====================================================================
// JSON field extractors — find known fields in a JSON object
// =====================================================================

/// Find a string field: "field_name":"value"
/// Returns the unescaped value or null if not found.
/// Does NOT handle escaped quotes inside values (sufficient for product names).
fn json_string_field(json: []const u8, field: []const u8) ?[]const u8 {
    // Search for "field":
    var pos: usize = 0;
    while (pos < json.len) {
        // Find next quote.
        const q = std.mem.indexOf(u8, json[pos..], "\"") orelse return null;
        const abs_q = pos + q;

        // Check if field name matches.
        if (abs_q + 1 + field.len + 3 > json.len) {
            pos = abs_q + 1;
            continue;
        }

        if (std.mem.eql(u8, json[abs_q + 1 ..][0..field.len], field)) {
            const after_field = abs_q + 1 + field.len;
            if (after_field + 3 <= json.len and std.mem.eql(u8, json[after_field..][0..3], "\":\"")) {
                const val_start = after_field + 3;
                // Find closing quote (simple — no escape handling).
                const val_end = std.mem.indexOf(u8, json[val_start..], "\"") orelse return null;
                return json[val_start..][0..val_end];
            }
        }
        pos = abs_q + 1;
    }
    return null;
}

/// Find a numeric field: "field_name":12345
fn json_u32_field(json: []const u8, field: []const u8) ?u32 {
    // Search for "field":
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
                // Find end of number (next non-digit).
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
fn json_bool_field(json: []const u8, field: []const u8) ?bool {
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

/// Parse a 32-character hex string as a u128 UUID. Returns null on invalid input.
/// Accepts exactly 32 lowercase hex characters (no dashes).
/// Parse ?after=<uuid> from a query string. Returns 0 if absent or malformed.
fn parse_query_cursor(query: []const u8) u128 {
    const prefix = "after=";
    var pos: usize = 0;
    while (pos < query.len) {
        // Find start of next parameter.
        if (pos > 0) pos += 1; // skip '&'
        const rest = query[pos..];
        if (std.mem.startsWith(u8, rest, prefix)) {
            const value_start = pos + prefix.len;
            const value_end = std.mem.indexOf(u8, query[value_start..], "&") orelse query.len - value_start;
            return parse_uuid(query[value_start..][0..value_end]) orelse 0;
        }
        // Skip to next '&'.
        pos = if (std.mem.indexOf(u8, rest, "&")) |amp| pos + amp else query.len;
    }
    return 0;
}

fn parse_uuid(s: []const u8) ?u128 {
    if (s.len != 32) return null;
    var result: u128 = 0;
    for (s) |c| {
        const digit: u128 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => return null,
        };
        result = (result << 4) | digit;
    }
    return result;
}

/// Format a u128 as a 32-character lowercase hex string.
fn write_uuid_to_buf(buf: *[32]u8, val: u128) void {
    const hex = "0123456789abcdef";
    var v = val;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@intCast(v & 0xf)];
        v >>= 4;
    }
}

/// Format a u64 as a decimal string.
fn format_u64(buf: *[20]u8, val: u64) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = val;
    var pos: usize = 20;
    while (v > 0) {
        pos -= 1;
        buf[pos] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    return buf[pos..20];
}

/// Format a u32 as a decimal string.
fn format_u32(buf: *[10]u8, val: u32) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = val;
    var pos: usize = 10;
    while (v > 0) {
        pos -= 1;
        buf[pos] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    return buf[pos..10];
}

// =====================================================================
// Tests
// =====================================================================

const test_uuid_str = "aabbccdd11223344aabbccdd11223344";
const test_uuid: u128 = 0xaabbccdd11223344aabbccdd11223344;

test "GET /products (list)" {
    const msg = translate(.get, "/products", "").?;
    try std.testing.expectEqual(msg.operation, .list_products);
    try std.testing.expectEqual(msg.id, 0);
    try std.testing.expectEqual(msg.event.list.cursor, 0);
}

test "GET /products/:id (get)" {
    const msg = translate(.get, "/products/" ++ test_uuid_str, "").?;
    try std.testing.expectEqual(msg.operation, .get_product);
    try std.testing.expectEqual(msg.id, test_uuid);
}

test "POST /products (create)" {
    const body =
        \\{"id":"aabbccdd11223344aabbccdd11223344","name":"Widget","description":"A small widget","price_cents":999,"inventory":50,"active":true}
    ;
    const msg = translate(.post, "/products", body).?;
    try std.testing.expectEqual(msg.operation, .create_product);
    try std.testing.expectEqual(msg.id, 0);
    const p = msg.event.product;
    try std.testing.expectEqual(p.id, test_uuid);
    try std.testing.expectEqualSlices(u8, p.name_slice(), "Widget");
    try std.testing.expectEqualSlices(u8, p.description_slice(), "A small widget");
    try std.testing.expectEqual(p.price_cents, 999);
    try std.testing.expectEqual(p.inventory, 50);
    try std.testing.expect(p.active);
}

test "PUT /products/:id (update)" {
    const msg = translate(.put, "/products/" ++ test_uuid_str,
        \\{"name":"Updated"}
    ).?;
    try std.testing.expectEqual(msg.operation, .update_product);
    try std.testing.expectEqual(msg.id, test_uuid);
    try std.testing.expect(msg.event == .product);
}

test "DELETE /products/:id (delete)" {
    const msg = translate(.delete, "/products/" ++ test_uuid_str, "").?;
    try std.testing.expectEqual(msg.operation, .delete_product);
    try std.testing.expectEqual(msg.id, test_uuid);
}

test "rejects unknown collection" {
    try std.testing.expect(translate(.get, "/widgets", "") == null);
    try std.testing.expect(translate(.get, "/", "") == null);
    try std.testing.expect(translate(.get, "", "") == null);
}

test "rejects invalid method/path combos" {
    // POST with ID.
    try std.testing.expect(translate(.post, "/products/" ++ test_uuid_str,
        \\{"name":"X"}
    ) == null);
    // PUT without ID.
    try std.testing.expect(translate(.put, "/products",
        \\{"name":"X"}
    ) == null);
    // DELETE without ID.
    try std.testing.expect(translate(.delete, "/products", "") == null);
}

test "rejects invalid UUID in path" {
    // Too short.
    try std.testing.expect(translate(.get, "/products/123", "") == null);
    // Uppercase not accepted.
    try std.testing.expect(translate(.get, "/products/AABBCCDD11223344AABBCCDD11223344", "") == null);
    // Non-hex chars.
    try std.testing.expect(translate(.get, "/products/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", "") == null);
}

test "strips query string" {
    const msg = translate(.get, "/products?page=1", "").?;
    try std.testing.expectEqual(msg.operation, .list_products);
    try std.testing.expectEqual(msg.event.list.cursor, 0);
}

test "parses after cursor from query string" {
    const msg = translate(.get, "/products?after=00000000000000000000000000000abc", "").?;
    try std.testing.expectEqual(msg.operation, .list_products);
    try std.testing.expectEqual(msg.event.list.cursor, 0xabc);
}

test "cursor with other query params" {
    const msg = translate(.get, "/products?limit=10&after=00000000000000000000000000000042&foo=bar", "").?;
    try std.testing.expectEqual(msg.event.list.cursor, 0x42);
}

test "invalid cursor ignored" {
    const msg = translate(.get, "/products?after=notauuid", "").?;
    try std.testing.expectEqual(msg.event.list.cursor, 0);
}

test "GET rejects non-empty body" {
    try std.testing.expect(translate(.get, "/products/" ++ test_uuid_str, "data") == null);
}

test "POST rejects empty body" {
    try std.testing.expect(translate(.post, "/products", "") == null);
}

test "POST rejects missing name" {
    try std.testing.expect(translate(.post, "/products",
        \\{"id":"aabbccdd11223344aabbccdd11223344","price_cents":100}
    ) == null);
}

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

test "encode_response_json — single product" {
    var p = message.Product{
        .id = 0xaabbccdd11223344aabbccdd11223344,
        .name = undefined,
        .name_len = 6,
        .description = undefined,
        .description_len = 4,
        .price_cents = 999,
        .inventory = 10,
        .version = 1,
        .active = true,
    };
    @memcpy(p.name[0..6], "Widget");
    @memcpy(p.description[0..4], "Cool");

    const resp = message.MessageResponse{
        .status = .ok,
        .result = .{ .product = p },
    };

    var buf: [4096]u8 = undefined;
    const json = encode_response_json(&buf, resp);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"" ++ test_uuid_str ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Widget\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"price_cents\":999") != null);
}

test "parse_uuid and write_uuid roundtrip" {
    const uuid = parse_uuid("0123456789abcdef0123456789abcdef").?;
    var buf: [32]u8 = undefined;
    write_uuid_to_buf(&buf, uuid);
    try std.testing.expectEqualSlices(u8, &buf, "0123456789abcdef0123456789abcdef");
}

test "parse_uuid rejects invalid input" {
    try std.testing.expect(parse_uuid("123") == null); // too short
    try std.testing.expect(parse_uuid("AABBCCDD11223344AABBCCDD11223344") == null); // uppercase
    try std.testing.expect(parse_uuid("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz") == null); // non-hex
}

test "encode_response_json — not found" {
    var buf: [4096]u8 = undefined;
    const json = encode_response_json(&buf, message.MessageResponse.not_found);
    try std.testing.expectEqualSlices(u8, json, "{\"error\":\"not found\"}");
}

test "encode_response_json — empty list" {
    var buf: [4096]u8 = undefined;
    const json = encode_response_json(&buf, message.MessageResponse.empty_ok);
    try std.testing.expectEqualSlices(u8, json, "[]");
}

test "GET /products/:id/inventory (get_inventory)" {
    const msg = translate(.get, "/products/" ++ test_uuid_str ++ "/inventory", "").?;
    try std.testing.expectEqual(msg.operation, .get_product_inventory);
    try std.testing.expectEqual(msg.id, test_uuid);
    try std.testing.expectEqual(msg.event, .none);
}

test "rejects unknown sub-resource" {
    try std.testing.expect(translate(.get, "/products/" ++ test_uuid_str ++ "/unknown", "") == null);
}

const test_uuid2_str = "aabbccdd11223344aabbccdd11223345";
const test_uuid2: u128 = 0xaabbccdd11223344aabbccdd11223345;

test "POST /products/:id/transfer-inventory/:target_id" {
    const msg = translate(.post, "/products/" ++ test_uuid_str ++ "/transfer-inventory/" ++ test_uuid2_str,
        \\{"quantity":10}
    ).?;
    try std.testing.expectEqual(msg.operation, .transfer_inventory);
    try std.testing.expectEqual(msg.id, test_uuid);
    try std.testing.expectEqual(msg.event.transfer.target_id, test_uuid2);
    try std.testing.expectEqual(msg.event.transfer.quantity, 10);
}

test "transfer-inventory rejects zero quantity" {
    try std.testing.expect(translate(.post, "/products/" ++ test_uuid_str ++ "/transfer-inventory/" ++ test_uuid2_str,
        \\{"quantity":0}
    ) == null);
}

test "transfer-inventory rejects empty body" {
    try std.testing.expect(translate(.post, "/products/" ++ test_uuid_str ++ "/transfer-inventory/" ++ test_uuid2_str, "") == null);
}

test "transfer-inventory rejects same source and target" {
    try std.testing.expect(translate(.post, "/products/" ++ test_uuid_str ++ "/transfer-inventory/" ++ test_uuid_str,
        \\{"quantity":5}
    ) == null);
}

test "transfer-inventory rejects missing target" {
    try std.testing.expect(translate(.post, "/products/" ++ test_uuid_str ++ "/transfer-inventory",
        \\{"quantity":5}
    ) == null);
}

test "POST /orders (create_order)" {
    const body =
        \\{"id":"eeee0000000000000000000000000001","items":[{"product_id":"aabbccdd11223344aabbccdd11223344","quantity":2},{"product_id":"aabbccdd11223344aabbccdd11223345","quantity":3}]}
    ;
    const msg = translate(.post, "/orders", body).?;
    try std.testing.expectEqual(msg.operation, .create_order);
    const order = msg.event.order;
    try std.testing.expectEqual(order.id, 0xeeee0000000000000000000000000001);
    try std.testing.expectEqual(order.items_len, 2);
    try std.testing.expectEqual(order.items[0].product_id, test_uuid);
    try std.testing.expectEqual(order.items[0].quantity, 2);
    try std.testing.expectEqual(order.items[1].product_id, test_uuid2);
    try std.testing.expectEqual(order.items[1].quantity, 3);
}

test "POST /orders rejects empty items" {
    try std.testing.expect(translate(.post, "/orders",
        \\{"id":"eeee0000000000000000000000000001","items":[]}
    ) == null);
}

test "POST /orders rejects missing id" {
    try std.testing.expect(translate(.post, "/orders",
        \\{"items":[{"product_id":"aabbccdd11223344aabbccdd11223344","quantity":1}]}
    ) == null);
}

test "POST /orders rejects zero quantity" {
    try std.testing.expect(translate(.post, "/orders",
        \\{"id":"eeee0000000000000000000000000001","items":[{"product_id":"aabbccdd11223344aabbccdd11223344","quantity":0}]}
    ) == null);
}

test "POST /orders rejects duplicate product_id" {
    try std.testing.expect(translate(.post, "/orders",
        \\{"id":"eeee0000000000000000000000000001","items":[{"product_id":"aabbccdd11223344aabbccdd11223344","quantity":1},{"product_id":"aabbccdd11223344aabbccdd11223344","quantity":2}]}
    ) == null);
}

test "GET /orders (list)" {
    const msg = translate(.get, "/orders", "").?;
    try std.testing.expectEqual(msg.operation, .list_orders);
}

test "GET /orders/:id (get)" {
    const msg = translate(.get, "/orders/" ++ test_uuid_str, "").?;
    try std.testing.expectEqual(msg.operation, .get_order);
    try std.testing.expectEqual(msg.id, test_uuid);
}

test "encode_response_json — order" {
    var order_result = message.OrderResult{
        .id = 0xeeee0000000000000000000000000001,
        .items = undefined,
        .items_len = 1,
        .total_cents = 1998,
    };
    order_result.items[0] = .{
        .product_id = test_uuid,
        .name = undefined,
        .name_len = 6,
        .quantity = 2,
        .price_cents = 999,
        .line_total_cents = 1998,
    };
    @memcpy(order_result.items[0].name[0..6], "Widget");

    const resp = message.MessageResponse{
        .status = .ok,
        .result = .{ .order = order_result },
    };

    var buf: [4096]u8 = undefined;
    const json = encode_response_json(&buf, resp);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_cents\":1998") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"line_total_cents\":1998") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Widget\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"quantity\":2") != null);
}

test "encode_response_json — inventory" {
    const resp = message.MessageResponse{
        .status = .ok,
        .result = .{ .inventory = 42 },
    };

    var buf: [4096]u8 = undefined;
    const json = encode_response_json(&buf, resp);
    try std.testing.expectEqualSlices(u8, json, "{\"inventory\":42}");
}
