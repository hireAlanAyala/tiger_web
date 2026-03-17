const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");
const message = @import("message.zig");
const http = @import("http.zig");

const log = std.log.scoped(.codec);

/// Translate an HTTP method + path + body into a typed Message.
/// Path format: /resource or /resource/:id or /resource/:id/sub/:sub_id
/// Returns null if the request doesn't map to a valid operation.
pub fn translate(method: http.Method, raw_path: []const u8, body: []const u8) ?message.Message {
    // Strip leading /.
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const path = raw_path[1..];

    // GET / → page_load_dashboard
    if (path.len == 0) {
        if (method != .get) return null;
        return message.Message.init(.page_load_dashboard, 0, 0, {});
    }

    // Split path from query string.
    const query_sep = std.mem.indexOf(u8, path, "?");
    const path_clean = if (query_sep) |q| path[0..q] else path;
    const query_string = if (query_sep) |q| path[q + 1 ..] else "";

    // Parse list parameters from query string.
    const list_params = parse_list_params(query_string);

    // Split path into up to 4 segments: /resource/:id/sub/:sub_id
    const segments = split_path(path_clean) orelse return null;

    // Products default to active_only when ?active is not specified.
    const has_active_param = query_param(query_string, "active") != null;

    // Match resource and resolve to flat operation.
    return if (std.mem.eql(u8, segments.collection, "products"))
        translate_products(method, segments, body, list_params, has_active_param, query_string)
    else if (std.mem.eql(u8, segments.collection, "collections"))
        translate_collections(method, segments, body, list_params)
    else if (std.mem.eql(u8, segments.collection, "orders"))
        translate_orders(method, segments, body, list_params)
    else
        reject("unknown resource");
}

/// Log a debug message explaining why translate() rejected a request, then return null.
/// Only visible with --log-debug. Zero cost in production (compiled but filtered at runtime).
fn reject(comptime reason: []const u8) ?message.Message {
    log.debug("translate: rejected: " ++ reason, .{});
    return null;
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

fn translate_products(method: http.Method, seg: PathSegments, body: []const u8, list_params: message.ListParams, has_active_param: bool, query_string: []const u8) ?message.Message {
    // POST /products/:id/transfer-inventory/:target_id — uses sub_id for target.
    if (seg.has_id and seg.sub_resource.len > 0 and method == .post) {
        if (std.mem.eql(u8, seg.sub_resource, "transfer-inventory") and seg.has_sub_id) {
            if (body.len == 0) return reject("transfer_inventory: missing body");
            const quantity = json_u32_field(body, "quantity") orelse return reject("transfer_inventory: missing or invalid quantity");
            if (quantity == 0) return reject("transfer_inventory: quantity is zero");
            if (seg.id == 0 or seg.sub_id == 0) return reject("transfer_inventory: invalid id in path");
            if (seg.id == seg.sub_id) return reject("transfer_inventory: source and target are the same");
            return message.Message.init(.transfer_inventory, seg.id, 0, message.InventoryTransfer{
                .target_id = seg.sub_id,
                .quantity = quantity,
                .reserved = .{0} ** 12,
            });
        }
        return reject("products: unknown sub-resource for POST");
    }

    const operation: message.Operation = switch (method) {
        .get => blk: {
            if (seg.has_id and seg.sub_resource.len > 0) {
                if (std.mem.eql(u8, seg.sub_resource, "inventory")) break :blk .get_product_inventory;
                return reject("products: unknown sub-resource for GET");
            }
            if (!seg.has_id) {
                // GET /products?q=... → full-text search.
                if (query_param(query_string, "q")) |_| break :blk .search_products;
                break :blk .list_products;
            }
            break :blk .get_product;
        },
        .post => if (!seg.has_id) .create_product else return reject("create_product: unexpected id in path"),
        .put => if (seg.has_id and seg.id != 0) .update_product else return reject("update_product: missing or invalid id in path"),
        .delete => if (seg.has_id) .delete_product else return reject("delete_product: missing id in path"),
    };

    switch (operation) {
        .search_products => {
            if (body.len != 0) return reject("search_products: unexpected body");
            const q = query_param(query_string, "q") orelse return reject("search_products: missing q param");
            if (q.len == 0 or q.len > message.search_query_max) return reject("search_products: q empty or too long");
            var sq = std.mem.zeroes(message.SearchQuery);
            @memcpy(sq.query[0..q.len], q);
            sq.query_len = @intCast(q.len);
            return message.Message.init(.search_products, 0, 0, sq);
        },
        .list_products => {
            if (body.len != 0) return reject("list_products: unexpected body");
            var params = list_params;
            // Default to active_only — soft-deleted items hidden unless
            // the client explicitly passes ?active=false or ?active=all.
            if (!has_active_param) params.active_filter = .active_only;
            return message.Message.init(operation, 0, 0, params);
        },
        .get_product, .delete_product, .get_product_inventory => {
            if (body.len != 0) return reject("get/delete product: unexpected body");
            return message.Message.init(operation, seg.id, 0, {});
        },
        .create_product, .update_product => {
            if (body.len == 0) return reject("create/update product: missing body");
            const product = parse_product_json(body) orelse return reject("create/update product: invalid JSON");
            // create requires a client-provided ID; update requires a path ID.
            if (operation == .create_product and product.id == 0) return reject("create_product: missing id in body");
            return message.Message.init(operation, seg.id, 0, product);
        },
        else => return null,
    }
}

fn translate_collections(method: http.Method, seg: PathSegments, body: []const u8, list_params: message.ListParams) ?message.Message {
    // /collections/:id/products/:product_id — membership operations.
    if (seg.has_id and seg.sub_resource.len > 0) {
        if (!std.mem.eql(u8, seg.sub_resource, "products")) return reject("collections: unknown sub-resource");
        if (!seg.has_sub_id) return reject("collection_member: missing product_id in path");

        const operation: message.Operation = switch (method) {
            .post => .add_collection_member,
            .delete => .remove_collection_member,
            else => return reject("collection_member: unsupported method"),
        };

        if (body.len != 0) return reject("collection_member: unexpected body");
        return message.Message.init(operation, seg.id, 0, seg.sub_id);
    }

    const operation: message.Operation = switch (method) {
        .get => if (seg.has_id) .get_collection else .list_collections,
        .post => if (!seg.has_id) .create_collection else return reject("create_collection: unexpected id in path"),
        .delete => if (seg.has_id) .delete_collection else return reject("delete_collection: missing id in path"),
        else => return reject("collections: unsupported method"),
    };

    switch (operation) {
        .list_collections => {
            if (body.len != 0) return reject("list_collections: unexpected body");
            return message.Message.init(operation, 0, 0, list_params);
        },
        .get_collection, .delete_collection => {
            if (body.len != 0) return reject("get/delete collection: unexpected body");
            return message.Message.init(operation, seg.id, 0, {});
        },
        .create_collection => {
            if (body.len == 0) return reject("create_collection: missing body");
            return message.Message.init(operation, seg.id, 0, parse_collection_json(body) orelse return reject("create_collection: invalid JSON"));
        },
        else => return null,
    }
}

fn translate_orders(method: http.Method, seg: PathSegments, body: []const u8, list_params: message.ListParams) ?message.Message {
    switch (method) {
        .get => {
            if (body.len != 0) return reject("get orders: unexpected body");
            if (seg.has_id) {
                return message.Message.init(.get_order, seg.id, 0, {});
            } else {
                return message.Message.init(.list_orders, 0, 0, list_params);
            }
        },
        .post => {
            // POST /orders/:id/complete — two-phase completion
            if (seg.has_id and seg.sub_resource.len > 0 and std.mem.eql(u8, seg.sub_resource, "complete")) {
                if (body.len == 0) return reject("complete_order: missing body");
                const completion = parse_completion_json(body) orelse return reject("complete_order: invalid JSON");
                return message.Message.init(.complete_order, seg.id, 0, completion);
            }
            // POST /orders/:id/cancel — client cancellation
            if (seg.has_id and seg.sub_resource.len > 0 and std.mem.eql(u8, seg.sub_resource, "cancel")) {
                return message.Message.init(.cancel_order, seg.id, 0, {});
            }
            // POST /orders — create order
            if (seg.has_id) return reject("create_order: unexpected id in path");
            if (body.len == 0) return reject("create_order: missing body");
            const order = parse_order_json(body) orelse return reject("create_order: invalid JSON");
            return message.Message.init(.create_order, order.id, 0, order);
        },
        else => return reject("orders: unsupported method"),
    }
}

/// Parse a JSON body into an OrderCompletion.
/// Expected format: {"result":"confirmed","payment_ref":"ch_xxx"} or {"result":"failed"}
fn parse_completion_json(body: []const u8) ?message.OrderCompletion {
    const result_str = json_string_field(body, "result") orelse return null;
    const result: message.OrderCompletion.OrderCompletionResult =
        if (std.mem.eql(u8, result_str, "confirmed"))
            .confirmed
        else if (std.mem.eql(u8, result_str, "failed"))
            .failed
        else
            return null;

    var completion = std.mem.zeroes(message.OrderCompletion);
    completion.result = result;

    // Optional payment_ref — typically present on confirmed completions.
    if (json_string_field(body, "payment_ref")) |ref| {
        if (ref.len > 0 and ref.len <= message.payment_ref_max) {
            @memcpy(completion.payment_ref[0..ref.len], ref);
            completion.payment_ref_len = @intCast(ref.len);
        }
    }

    return completion;
}

/// Parse a JSON body into an OrderRequest.
/// Expected format:
/// {"id":"...","items":[{"product_id":"...","quantity":N},...]}
fn parse_order_json(body: []const u8) ?message.OrderRequest {
    var order = std.mem.zeroes(message.OrderRequest);

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
            .reserved = .{0} ** 12,
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
    var product = std.mem.zeroes(message.Product);
    product.flags = .{ .active = true };

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
        product.flags.active = a;
    }

    return product;
}

/// Parse a JSON body into a ProductCollection struct.
/// Expected: {"id":"...","name":"..."}
/// ID is required (client-provided). Name is required.
fn parse_collection_json(body: []const u8) ?message.ProductCollection {
    var col = std.mem.zeroes(message.ProductCollection);

    const id_str = json_string_field(body, "id") orelse return null;
    col.id = parse_uuid(id_str) orelse return null;
    if (col.id == 0) return null;

    const name = json_string_field(body, "name") orelse return null;
    if (name.len == 0 or name.len > message.collection_name_max) return null;
    @memcpy(col.name[0..name.len], name);
    col.name_len = @intCast(name.len);

    return col;
}

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

/// Extract the value of a query parameter by key. Returns null if not found.
fn query_param(query: []const u8, key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < query.len) {
        // Skip leading/consecutive '&' separators.
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

/// Parse list parameters from a query string: pagination cursor and filters.
fn parse_list_params(query: []const u8) message.ListParams {
    var params = std.mem.zeroes(message.ListParams);

    if (query_param(query, "after")) |v| {
        params.cursor = parse_uuid(v) orelse 0;
    }
    if (query_param(query, "active")) |v| {
        if (std.mem.eql(u8, v, "true")) {
            params.active_filter = .active_only;
        } else if (std.mem.eql(u8, v, "false")) {
            params.active_filter = .inactive_only;
        }
        // "all" or any unrecognized value → .any (no filter).
    }
    if (query_param(query, "price_min")) |v| {
        params.price_min = parse_query_u32(v);
    }
    if (query_param(query, "price_max")) |v| {
        params.price_max = parse_query_u32(v);
    }
    if (query_param(query, "name_prefix")) |v| {
        if (v.len > 0 and v.len <= message.product_name_max) {
            @memcpy(params.name_prefix[0..v.len], v);
            params.name_prefix_len = @intCast(v.len);
        }
    }

    return params;
}

/// Parse a decimal string as u32. Returns 0 on invalid input.
fn parse_query_u32(s: []const u8) u32 {
    if (s.len == 0 or s.len > 10) return 0;
    var result: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return 0;
        result = std.math.mul(u32, result, 10) catch return 0;
        result = std.math.add(u32, result, c - '0') catch return 0;
    }
    return result;
}

const parse_uuid = stdx.parse_uuid;

/// Format a u128 as a 32-character lowercase hex string.
// format_u32, format_u64, write_uuid_to_buf are in stdx.zig.

// =====================================================================
// Tests
// =====================================================================

const test_uuid_str = "aabbccdd11223344aabbccdd11223344";
const test_uuid: u128 = 0xaabbccdd11223344aabbccdd11223344;

/// Test helper: translate with is_datastar_request=false, return just the message.
fn test_translate(method: http.Method, raw_path: []const u8, body: []const u8) ?message.Message {
    return translate(method, raw_path, body);
}

test "GET /products (list)" {
    const msg = test_translate(.get, "/products", "").?;
    try std.testing.expectEqual(msg.operation, .list_products);
    try std.testing.expectEqual(msg.id, 0);
    try std.testing.expectEqual(msg.body_as(message.ListParams).cursor, 0);
    try std.testing.expectEqual(msg.body_as(message.ListParams).active_filter, .active_only);
}

test "GET /products?active=all shows all" {
    const msg = test_translate(.get, "/products?active=all", "").?;
    try std.testing.expectEqual(msg.body_as(message.ListParams).active_filter, .any);
}

test "GET /products/:id (get)" {
    const msg = test_translate(.get, "/products/" ++ test_uuid_str, "").?;
    try std.testing.expectEqual(msg.operation, .get_product);
    try std.testing.expectEqual(msg.id, test_uuid);
}

test "POST /products (create)" {
    const body =
        \\{"id":"aabbccdd11223344aabbccdd11223344","name":"Widget","description":"A small widget","price_cents":999,"inventory":50,"active":true}
    ;
    const msg = test_translate(.post, "/products", body).?;
    try std.testing.expectEqual(msg.operation, .create_product);
    try std.testing.expectEqual(msg.id, 0);
    const p = msg.body_as(message.Product).*;
    try std.testing.expectEqual(p.id, test_uuid);
    try std.testing.expectEqualSlices(u8, p.name_slice(), "Widget");
    try std.testing.expectEqualSlices(u8, p.description_slice(), "A small widget");
    try std.testing.expectEqual(p.price_cents, 999);
    try std.testing.expectEqual(p.inventory, 50);
    try std.testing.expect(p.flags.active);
}

test "PUT /products/:id (update)" {
    const msg = test_translate(.put, "/products/" ++ test_uuid_str,
        \\{"name":"Updated"}
    ).?;
    try std.testing.expectEqual(msg.operation, .update_product);
    try std.testing.expectEqual(msg.id, test_uuid);
    try std.testing.expectEqual(msg.operation, .update_product);
}

test "DELETE /products/:id (delete)" {
    const msg = test_translate(.delete, "/products/" ++ test_uuid_str, "").?;
    try std.testing.expectEqual(msg.operation, .delete_product);
    try std.testing.expectEqual(msg.id, test_uuid);
}

test "GET / routes to page_load_dashboard" {
    const msg = test_translate(.get, "/", "").?;
    try std.testing.expectEqual(msg.operation, .page_load_dashboard);
}

test "rejects unknown collection" {
    try std.testing.expect(test_translate(.get, "/widgets", "") == null);
    try std.testing.expect(test_translate(.get, "", "") == null);
}

test "rejects invalid method/path combos" {
    // POST with ID.
    try std.testing.expect(test_translate(.post, "/products/" ++ test_uuid_str,
        \\{"name":"X"}
    ) == null);
    // PUT without ID.
    try std.testing.expect(test_translate(.put, "/products",
        \\{"name":"X"}
    ) == null);
    // DELETE without ID.
    try std.testing.expect(test_translate(.delete, "/products", "") == null);
}

test "rejects invalid UUID in path" {
    // Too short.
    try std.testing.expect(test_translate(.get, "/products/123", "") == null);
    // Uppercase not accepted.
    try std.testing.expect(test_translate(.get, "/products/AABBCCDD11223344AABBCCDD11223344", "") == null);
    // Non-hex chars.
    try std.testing.expect(test_translate(.get, "/products/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", "") == null);
}

test "strips query string" {
    const msg = test_translate(.get, "/products?page=1", "").?;
    try std.testing.expectEqual(msg.operation, .list_products);
    try std.testing.expectEqual(msg.body_as(message.ListParams).cursor, 0);
    // Products default to active_only when ?active not specified.
    try std.testing.expectEqual(msg.body_as(message.ListParams).active_filter, .active_only);
}

test "parses after cursor from query string" {
    const msg = test_translate(.get, "/products?after=00000000000000000000000000000abc", "").?;
    try std.testing.expectEqual(msg.operation, .list_products);
    try std.testing.expectEqual(msg.body_as(message.ListParams).cursor, 0xabc);
}

test "cursor with other query params" {
    const msg = test_translate(.get, "/products?limit=10&after=00000000000000000000000000000042&foo=bar", "").?;
    try std.testing.expectEqual(msg.body_as(message.ListParams).cursor, 0x42);
}

test "invalid cursor ignored" {
    const msg = test_translate(.get, "/products?after=notauuid", "").?;
    try std.testing.expectEqual(msg.body_as(message.ListParams).cursor, 0);
}

test "parses active filter from query string" {
    const msg1 = test_translate(.get, "/products?active=true", "").?;
    try std.testing.expectEqual(msg1.body_as(message.ListParams).active_filter, .active_only);

    const msg2 = test_translate(.get, "/products?active=false", "").?;
    try std.testing.expectEqual(msg2.body_as(message.ListParams).active_filter, .inactive_only);

    const msg3 = test_translate(.get, "/products?active=maybe", "").?;
    try std.testing.expectEqual(msg3.body_as(message.ListParams).active_filter, .any);
}

test "parses price range from query string" {
    const msg = test_translate(.get, "/products?price_min=500&price_max=2000", "").?;
    try std.testing.expectEqual(msg.body_as(message.ListParams).price_min, 500);
    try std.testing.expectEqual(msg.body_as(message.ListParams).price_max, 2000);
}

test "parses name prefix from query string" {
    const msg = test_translate(.get, "/products?name_prefix=Widget", "").?;
    try std.testing.expectEqualSlices(u8, msg.body_as(message.ListParams).name_prefix_slice(), "Widget");
}

test "GET rejects non-empty body" {
    try std.testing.expect(test_translate(.get, "/products/" ++ test_uuid_str, "data") == null);
}

test "POST rejects empty body" {
    try std.testing.expect(test_translate(.post, "/products", "") == null);
}

test "POST rejects missing name" {
    try std.testing.expect(test_translate(.post, "/products",
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

test "parse_uuid and write_uuid roundtrip" {
    const uuid = parse_uuid("0123456789abcdef0123456789abcdef").?;
    var buf: [32]u8 = undefined;
    stdx.write_uuid_to_buf(&buf, uuid);
    try std.testing.expectEqualSlices(u8, &buf, "0123456789abcdef0123456789abcdef");
}

test "parse_uuid rejects invalid input" {
    try std.testing.expect(parse_uuid("123") == null); // too short
    try std.testing.expect(parse_uuid("AABBCCDD11223344AABBCCDD11223344") == null); // uppercase
    try std.testing.expect(parse_uuid("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz") == null); // non-hex
}

test "GET /products/:id/inventory (get_inventory)" {
    const msg = test_translate(.get, "/products/" ++ test_uuid_str ++ "/inventory", "").?;
    try std.testing.expectEqual(msg.operation, .get_product_inventory);
    try std.testing.expectEqual(msg.id, test_uuid);
    try std.testing.expectEqual(msg.operation, .get_product_inventory);
}

test "rejects unknown sub-resource" {
    try std.testing.expect(test_translate(.get, "/products/" ++ test_uuid_str ++ "/unknown", "") == null);
}

const test_uuid2_str = "aabbccdd11223344aabbccdd11223345";
const test_uuid2: u128 = 0xaabbccdd11223344aabbccdd11223345;

test "POST /products/:id/transfer-inventory/:target_id" {
    const msg = test_translate(.post, "/products/" ++ test_uuid_str ++ "/transfer-inventory/" ++ test_uuid2_str,
        \\{"quantity":10}
    ).?;
    try std.testing.expectEqual(msg.operation, .transfer_inventory);
    try std.testing.expectEqual(msg.id, test_uuid);
    try std.testing.expectEqual(msg.body_as(message.InventoryTransfer).target_id, test_uuid2);
    try std.testing.expectEqual(msg.body_as(message.InventoryTransfer).quantity, 10);
}

test "transfer-inventory rejects zero quantity" {
    try std.testing.expect(test_translate(.post, "/products/" ++ test_uuid_str ++ "/transfer-inventory/" ++ test_uuid2_str,
        \\{"quantity":0}
    ) == null);
}

test "transfer-inventory rejects empty body" {
    try std.testing.expect(test_translate(.post, "/products/" ++ test_uuid_str ++ "/transfer-inventory/" ++ test_uuid2_str, "") == null);
}

test "transfer-inventory rejects same source and target" {
    try std.testing.expect(test_translate(.post, "/products/" ++ test_uuid_str ++ "/transfer-inventory/" ++ test_uuid_str,
        \\{"quantity":5}
    ) == null);
}

test "transfer-inventory rejects missing target" {
    try std.testing.expect(test_translate(.post, "/products/" ++ test_uuid_str ++ "/transfer-inventory",
        \\{"quantity":5}
    ) == null);
}

test "POST /orders (create_order)" {
    const body =
        \\{"id":"eeee0000000000000000000000000001","items":[{"product_id":"aabbccdd11223344aabbccdd11223344","quantity":2},{"product_id":"aabbccdd11223344aabbccdd11223345","quantity":3}]}
    ;
    const msg = test_translate(.post, "/orders", body).?;
    try std.testing.expectEqual(msg.operation, .create_order);
    const order = msg.body_as(message.OrderRequest).*;
    try std.testing.expectEqual(order.id, 0xeeee0000000000000000000000000001);
    try std.testing.expectEqual(order.items_len, 2);
    try std.testing.expectEqual(order.items[0].product_id, test_uuid);
    try std.testing.expectEqual(order.items[0].quantity, 2);
    try std.testing.expectEqual(order.items[1].product_id, test_uuid2);
    try std.testing.expectEqual(order.items[1].quantity, 3);
}

test "POST /orders rejects empty items" {
    try std.testing.expect(test_translate(.post, "/orders",
        \\{"id":"eeee0000000000000000000000000001","items":[]}
    ) == null);
}

test "POST /orders rejects missing id" {
    try std.testing.expect(test_translate(.post, "/orders",
        \\{"items":[{"product_id":"aabbccdd11223344aabbccdd11223344","quantity":1}]}
    ) == null);
}

test "POST /orders rejects zero quantity" {
    try std.testing.expect(test_translate(.post, "/orders",
        \\{"id":"eeee0000000000000000000000000001","items":[{"product_id":"aabbccdd11223344aabbccdd11223344","quantity":0}]}
    ) == null);
}

test "POST /orders rejects duplicate product_id" {
    try std.testing.expect(test_translate(.post, "/orders",
        \\{"id":"eeee0000000000000000000000000001","items":[{"product_id":"aabbccdd11223344aabbccdd11223344","quantity":1},{"product_id":"aabbccdd11223344aabbccdd11223344","quantity":2}]}
    ) == null);
}

test "GET /orders (list)" {
    const msg = test_translate(.get, "/orders", "").?;
    try std.testing.expectEqual(msg.operation, .list_orders);
}

test "GET /orders/:id (get)" {
    const msg = test_translate(.get, "/orders/" ++ test_uuid_str, "").?;
    try std.testing.expectEqual(msg.operation, .get_order);
    try std.testing.expectEqual(msg.id, test_uuid);
}

// =====================================================================
// Seeded roundtrip tests — explore different inputs each run.
// Reproduce: ./zig/zig build unit-test -- --seed=<N>
// =====================================================================

const PRNG = @import("prng.zig");

test "seeded: UUID parse/write roundtrip" {
    var prng = PRNG.from_seed_testing();
    for (0..1000) |_| {
        const val = prng.int(u128);
        var buf: [32]u8 = undefined;
        stdx.write_uuid_to_buf(&buf, val);
        const parsed = parse_uuid(&buf).?;
        try std.testing.expectEqual(parsed, val);
    }
}

test "seeded: format_u32 roundtrip" {
    var prng = PRNG.from_seed_testing();
    for (0..1000) |_| {
        const val = prng.int(u32);
        var buf: [10]u8 = undefined;
        const s = stdx.format_u32(&buf, val);
        const parsed = std.fmt.parseInt(u32, s, 10) catch unreachable;
        try std.testing.expectEqual(parsed, val);
    }
}

test "seeded: format_u64 roundtrip" {
    var prng = PRNG.from_seed_testing();
    for (0..1000) |_| {
        const val = prng.int(u64);
        var buf: [20]u8 = undefined;
        const s = stdx.format_u64(&buf, val);
        const parsed = std.fmt.parseInt(u64, s, 10) catch unreachable;
        try std.testing.expectEqual(parsed, val);
    }
}

test "seeded: translate valid product JSON roundtrip" {
    var prng = PRNG.from_seed_testing();
    const hex = "0123456789abcdef";
    for (0..200) |_| {
        // Generate a random UUID string.
        var uuid_buf: [32]u8 = undefined;
        const id = prng.int(u128) | 1; // ensure non-zero
        stdx.write_uuid_to_buf(&uuid_buf, id);

        // Generate a random name (1..8 alpha chars).
        var name_buf: [8]u8 = undefined;
        const name_len = prng.range_inclusive(u32, 1, 8);
        for (name_buf[0..name_len]) |*c| {
            c.* = hex[prng.int_inclusive(u8, 15)];
        }
        const name = name_buf[0..name_len];

        // Build JSON body.
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"price_cents\":{d}}}", .{
            uuid_buf, name, prng.int_inclusive(u32, 99999),
        }) catch unreachable;

        const msg = test_translate(.post, "/products", body) orelse continue;
        try std.testing.expectEqual(msg.operation, .create_product);
        try std.testing.expectEqual(msg.body_as(message.Product).id, id);
        try std.testing.expectEqualSlices(u8, msg.body_as(message.Product).name_slice(), name);
    }
}
