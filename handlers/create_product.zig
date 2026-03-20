const std = @import("std");
const assert = std.debug.assert;
const fw = @import("tiger_framework");
const http = fw.http;
const parse = fw.parse;
const effects = fw.effects;
const handler = fw.handler;
const message = @import("../message.zig");
const Storage = @import("../storage.zig").SqliteStorage;
const stdx = fw.stdx;
const html = @import("../html.zig");
const get_product = @import("get_product.zig");

const ExecuteResult = @import("../state_machine.zig").StateMachineType(Storage).ExecuteResult;
const Write = @import("../state_machine.zig").StateMachineType(Storage).Write;

pub const Prefetch = struct {
    existing: ?get_product.ProductRow,
};

const Context = handler.HandlerContext(Prefetch, message.Operation.EventType(.create_product), message.PrefetchIdentity);

// [route] .create_product
pub fn route(method: http.Method, raw_path: []const u8, body: []const u8) ?message.Message {
    if (method != .post) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const path = raw_path[1..];

    const segments = parse.split_path(path) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "products")) return null;
    if (segments.has_id) return null; // POST /products, not /products/:id

    if (body.len == 0) return null;
    const product = parse_product_json(body) orelse return null;
    if (product.id == 0) return null;

    return message.Message.init(.create_product, product.id, 0, product);
}

// [prefetch] .create_product
pub fn prefetch(storage: *Storage, msg: *const message.Message) ?Prefetch {
    const existing = storage.query(
        get_product.ProductRow,
        "SELECT id, name, description, price_cents, inventory, version, description_len, name_len, active FROM products WHERE id = ?1;",
        .{msg.body_as(message.Product).id},
    );
    return .{ .existing = existing };
}

// [handle] .create_product
pub fn handle(ctx: Context) ExecuteResult {
    if (ctx.prefetched.existing != null) {
        return ExecuteResult.read_only(.{ .status = .version_conflict, .result = .{ .empty = {} } });
    }

    const event = ctx.body_val();

    // Reconstruct canonical product — zero padding, set defaults.
    var entity = std.mem.zeroes(message.Product);
    entity.id = event.id;
    @memcpy(entity.name[0..event.name_len], event.name[0..event.name_len]);
    entity.name_len = event.name_len;
    if (event.description_len > 0) {
        @memcpy(entity.description[0..event.description_len], event.description[0..event.description_len]);
    }
    entity.description_len = event.description_len;
    entity.price_cents = event.price_cents;
    entity.inventory = event.inventory;
    entity.version = 1;
    entity.flags = .{ .active = true };

    return ExecuteResult.single(
        .{ .status = .ok, .result = .{ .product = entity } },
        .{ .put_product = entity },
    );
}

// [render] .create_product
pub fn render(ctx: Context) effects.RenderResult {
    // TODO: render product card or error based on handle result.
    return ctx.render(.{});
}

/// Parse product JSON from request body.
fn parse_product_json(body: []const u8) ?message.Product {
    var p = std.mem.zeroes(message.Product);

    // ID (required for create).
    const id_str = parse.json_string_field(body, "id") orelse return null;
    p.id = stdx.parse_uuid(id_str) orelse return null;

    // Name (required).
    const name = parse.json_string_field(body, "name") orelse return null;
    if (name.len == 0 or name.len > message.product_name_max) return null;
    @memcpy(p.name[0..name.len], name);
    p.name_len = @intCast(name.len);

    // Description (optional).
    if (parse.json_string_field(body, "description")) |desc| {
        if (desc.len > message.product_description_max) return null;
        @memcpy(p.description[0..desc.len], desc);
        p.description_len = @intCast(desc.len);
    }

    // Price (optional, default 0).
    p.price_cents = parse.json_u32_field(body, "price_cents") orelse 0;

    // Inventory (optional, default 0).
    p.inventory = parse.json_u32_field(body, "inventory") orelse 0;

    // Active (optional, default true).
    p.flags = .{ .active = parse.json_bool_field(body, "active") orelse true };

    return p;
}
