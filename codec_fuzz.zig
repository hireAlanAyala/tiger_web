//! Codec fuzzer — throws random HTTP methods, paths, and JSON bodies at
//! codec.translate(), and random MessageResponse values at encode_response_json().
//!
//! Asserts: translate either returns a valid Message (passing input_valid)
//! or returns null — never panics, never triggers UB.
//! Asserts: encode_response_json always produces output that fits in the buffer.
//!
//! Follows TigerBeetle's fuzz pattern: library called by fuzz_tests.zig dispatcher.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const codec = @import("codec.zig");
const http = @import("http.zig");
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const PRNG = @import("prng.zig");

const StateMachine = state_machine.StateMachineType(state_machine.MemoryStorage);

const log = std.log.scoped(.fuzz);

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    _ = allocator;

    const seed = args.seed;
    const events_max = args.events_max orelse 50_000;
    var prng = PRNG.from_seed(seed);

    var translate_count: u64 = 0;
    var translate_valid: u64 = 0;
    var encode_count: u64 = 0;

    for (0..events_max) |event_i| {
        const phase = prng.chances(.{
            .translate = 7,
            .encode = 3,
        });

        log.debug("Running fuzz_ops[{}/{}] == {s}", .{ event_i, events_max, @tagName(phase) });

        switch (phase) {
            .translate => {
                if (fuzz_translate(&prng)) translate_valid += 1;
                translate_count += 1;
            },
            .encode => {
                fuzz_encode(&prng);
                encode_count += 1;
            },
        }
    }

    log.info(
        \\Codec fuzz done:
        \\  events_max={}
        \\  translate={} (valid={})
        \\  encode={}
    , .{ events_max, translate_count, translate_valid, encode_count });
}

// =====================================================================
// Translate fuzzer
// =====================================================================

/// Returns true if translate produced a valid message.
fn fuzz_translate(prng: *PRNG) bool {
    const method = gen_method(prng);
    var path_buf: [path_buf_max]u8 = undefined;
    const path = gen_path(prng, &path_buf);
    var body_buf: [body_buf_max]u8 = undefined;
    const body = gen_body(prng, &body_buf);

    const result = codec.translate(method, path, body);

    // Core invariant: if translate returns a message, it must pass input_valid.
    if (result) |msg| {
        assert(StateMachine.input_valid(msg));

        // Pair assertion: event tag matches operation.
        assert(msg.event == msg.operation.event_tag());
        return true;
    }
    return false;
}

// =====================================================================
// Encode fuzzer
// =====================================================================

fn fuzz_encode(prng: *PRNG) void {
    const resp = gen_response(prng);

    // Validate that what we're asking the encoder to produce is within bounds.
    // The encoder asserts internally when writes exceed the buffer.
    var buf: [http.send_buf_max]u8 = undefined;
    const json = codec.encode_response_json(&buf, resp);

    // Must produce non-empty output.
    assert(json.len > 0);
    // Must fit in the buffer.
    assert(json.len <= buf.len);
}

// =====================================================================
// HTTP method generation
// =====================================================================

fn gen_method(prng: *PRNG) http.Method {
    return prng.enum_uniform(http.Method);
}

// =====================================================================
// Path generation
// =====================================================================

const path_buf_max = 512;

/// Generate a random URL path. Mix of:
/// - Known valid resource paths (products, collections, orders)
/// - Mutated valid paths (wrong UUIDs, extra segments)
/// - Completely random bytes
fn gen_path(prng: *PRNG, buf: *[path_buf_max]u8) []const u8 {
    const strategy = prng.chances(.{
        .valid_resource = 4,
        .mutated_resource = 3,
        .random_bytes = 2,
        .edge_cases = 1,
    });

    return switch (strategy) {
        .valid_resource => gen_valid_path(prng, buf),
        .mutated_resource => gen_mutated_path(prng, buf),
        .random_bytes => gen_random_path(prng, buf),
        .edge_cases => gen_edge_case_path(prng, buf),
    };
}

const resources = [_][]const u8{ "products", "collections", "orders" };
const sub_resources = [_][]const u8{ "inventory", "transfer-inventory", "products" };

fn gen_valid_path(prng: *PRNG, buf: *[path_buf_max]u8) []const u8 {
    var pos: usize = 0;
    buf[pos] = '/';
    pos += 1;

    // Resource name.
    const resource = resources[prng.int_inclusive(usize, resources.len - 1)];
    @memcpy(buf[pos..][0..resource.len], resource);
    pos += resource.len;

    // Maybe add an ID.
    if (prng.boolean()) {
        buf[pos] = '/';
        pos += 1;
        const uuid = gen_uuid_string(prng);
        @memcpy(buf[pos..][0..32], &uuid);
        pos += 32;

        // Maybe add sub-resource.
        if (prng.boolean()) {
            buf[pos] = '/';
            pos += 1;
            const sub = sub_resources[prng.int_inclusive(usize, sub_resources.len - 1)];
            @memcpy(buf[pos..][0..sub.len], sub);
            pos += sub.len;

            // Maybe add sub-ID.
            if (prng.boolean()) {
                buf[pos] = '/';
                pos += 1;
                const sub_uuid = gen_uuid_string(prng);
                @memcpy(buf[pos..][0..32], &sub_uuid);
                pos += 32;
            }
        }
    }

    // Maybe add query string.
    if (prng.boolean()) {
        const qlen = gen_query_string(prng, buf[pos..]);
        pos += qlen;
    }

    return buf[0..pos];
}

fn gen_mutated_path(prng: *PRNG, buf: *[path_buf_max]u8) []const u8 {
    // Start with a valid path, then corrupt it.
    const base = gen_valid_path(prng, buf);
    const len = base.len;

    if (len == 0) return base;

    const mutation = prng.chances(.{
        .flip_byte = 3,
        .truncate = 2,
        .insert_byte = 2,
        .replace_uuid = 3,
    });

    switch (mutation) {
        .flip_byte => {
            const idx = prng.int_inclusive(usize, len - 1);
            buf[idx] ^= prng.bit(u8);
        },
        .truncate => {
            const new_len = prng.int_inclusive(usize, len - 1);
            return buf[0..new_len];
        },
        .insert_byte => {
            if (len < path_buf_max - 1) {
                const idx = prng.int_inclusive(usize, len);
                // Shift right.
                var i: usize = len;
                while (i > idx) : (i -= 1) {
                    buf[i] = buf[i - 1];
                }
                buf[idx] = prng.int(u8);
                return buf[0 .. len + 1];
            }
        },
        .replace_uuid => {
            // Find a '/' and replace the next 32 chars with garbage.
            for (buf[0..len], 0..) |c, i| {
                if (c == '/' and i + 33 <= len) {
                    const garbage_len = @min(32, len - i - 1);
                    for (buf[i + 1 ..][0..garbage_len]) |*b| {
                        b.* = prng.int(u8);
                    }
                    break;
                }
            }
        },
    }
    return buf[0..len];
}

fn gen_random_path(prng: *PRNG, buf: *[path_buf_max]u8) []const u8 {
    const len = prng.range_inclusive(usize, 0, 128);
    for (buf[0..len]) |*b| {
        b.* = prng.int(u8);
    }
    return buf[0..len];
}

fn gen_edge_case_path(prng: *PRNG, buf: *[path_buf_max]u8) []const u8 {
    const edge = prng.int_inclusive(usize, 7);
    const result: []const u8 = switch (edge) {
        0 => "",
        1 => "/",
        2 => "//",
        3 => "/products/",
        4 => "/products//",
        5 => "///products///",
        6 => blk: {
            // Path of all slashes.
            const len = prng.range_inclusive(usize, 1, 64);
            @memset(buf[0..len], '/');
            break :blk buf[0..len];
        },
        7 => blk: {
            // Very long path segment.
            const len = prng.range_inclusive(usize, 100, path_buf_max);
            for (buf[0..len]) |*b| {
                b.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
            }
            buf[0] = '/';
            break :blk buf[0..len];
        },
        else => unreachable,
    };
    if (result.ptr != buf.ptr and result.len > 0) {
        @memcpy(buf[0..result.len], result);
    }
    return buf[0..result.len];
}

fn gen_query_string(prng: *PRNG, buf: []u8) usize {
    if (buf.len < 2) return 0;
    var pos: usize = 0;
    buf[pos] = '?';
    pos += 1;

    const param_count = prng.range_inclusive(usize, 1, 4);
    for (0..param_count) |p| {
        if (p > 0) {
            if (pos >= buf.len) break;
            buf[pos] = '&';
            pos += 1;
        }

        const param = prng.int_inclusive(usize, 5);
        const kv: []const u8 = switch (param) {
            0 => "after=00000000000000000000000000000abc",
            1 => "active=true",
            2 => "active=false",
            3 => "price_min=100",
            4 => "price_max=5000",
            5 => "name_prefix=test",
            else => unreachable,
        };
        const copy_len = @min(kv.len, buf.len - pos);
        @memcpy(buf[pos..][0..copy_len], kv[0..copy_len]);
        pos += copy_len;
    }
    return pos;
}

// =====================================================================
// Body generation
// =====================================================================

const body_buf_max = http.body_max;

fn gen_body(prng: *PRNG, buf: *[body_buf_max]u8) []const u8 {
    const strategy = prng.chances(.{
        .empty = 3,
        .valid_json = 3,
        .mutated_json = 2,
        .random_bytes = 2,
    });

    return switch (strategy) {
        .empty => "",
        .valid_json => gen_valid_json(prng, buf),
        .mutated_json => gen_mutated_json(prng, buf),
        .random_bytes => gen_random_body(prng, buf),
    };
}

fn gen_valid_json(prng: *PRNG, buf: *[body_buf_max]u8) []const u8 {
    const variant = prng.int_inclusive(usize, 3);
    return switch (variant) {
        0 => gen_product_json(prng, buf),
        1 => gen_collection_json(prng, buf),
        2 => gen_order_json(prng, buf),
        3 => gen_transfer_json(prng, buf),
        else => unreachable,
    };
}

fn gen_product_json(prng: *PRNG, buf: *[body_buf_max]u8) []const u8 {
    var pos: usize = 0;

    pos += copy(buf[pos..], "{");

    // Maybe ID.
    if (prng.boolean()) {
        pos += copy(buf[pos..], "\"id\":\"");
        const uuid = gen_uuid_string(prng);
        pos += copy(buf[pos..], &uuid);
        pos += copy(buf[pos..], "\",");
    }

    // Name — sometimes valid, sometimes edge-case.
    pos += copy(buf[pos..], "\"name\":\"");
    const name_len = if (prng.chance(PRNG.ratio(8, 10)))
        prng.range_inclusive(usize, 1, @min(message.product_name_max, 64))
    else
        prng.range_inclusive(usize, 0, message.product_name_max + 10);
    const actual_name_len = @min(name_len, buf.len - pos - 64); // leave room for closing
    for (buf[pos..][0..actual_name_len]) |*c| {
        c.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
    }
    pos += actual_name_len;
    pos += copy(buf[pos..], "\"");

    // Maybe description.
    if (prng.boolean()) {
        pos += copy(buf[pos..], ",\"description\":\"");
        const desc_len = @min(
            prng.range_inclusive(usize, 0, 64),
            buf.len - pos - 64,
        );
        for (buf[pos..][0..desc_len]) |*c| {
            c.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
        }
        pos += desc_len;
        pos += copy(buf[pos..], "\"");
    }

    // Maybe price_cents.
    if (prng.boolean()) {
        pos += copy(buf[pos..], ",\"price_cents\":");
        pos += write_random_number(prng, buf[pos..]);
    }

    // Maybe inventory.
    if (prng.boolean()) {
        pos += copy(buf[pos..], ",\"inventory\":");
        pos += write_random_number(prng, buf[pos..]);
    }

    // Maybe version.
    if (prng.boolean()) {
        pos += copy(buf[pos..], ",\"version\":");
        pos += write_random_number(prng, buf[pos..]);
    }

    // Maybe active.
    if (prng.boolean()) {
        pos += copy(buf[pos..], ",\"active\":");
        pos += copy(buf[pos..], if (prng.boolean()) "true" else "false");
    }

    pos += copy(buf[pos..], "}");
    return buf[0..pos];
}

fn gen_collection_json(prng: *PRNG, buf: *[body_buf_max]u8) []const u8 {
    var pos: usize = 0;

    pos += copy(buf[pos..], "{");

    // Maybe ID.
    if (prng.boolean()) {
        pos += copy(buf[pos..], "\"id\":\"");
        const uuid = gen_uuid_string(prng);
        pos += copy(buf[pos..], &uuid);
        pos += copy(buf[pos..], "\",");
    }

    pos += copy(buf[pos..], "\"name\":\"");
    const name_len = @min(
        prng.range_inclusive(usize, 0, message.collection_name_max + 5),
        buf.len - pos - 16,
    );
    for (buf[pos..][0..name_len]) |*c| {
        c.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
    }
    pos += name_len;
    pos += copy(buf[pos..], "\"}");
    return buf[0..pos];
}

fn gen_order_json(prng: *PRNG, buf: *[body_buf_max]u8) []const u8 {
    var pos: usize = 0;

    pos += copy(buf[pos..], "{\"id\":\"");
    const uuid = gen_uuid_string(prng);
    pos += copy(buf[pos..], &uuid);
    pos += copy(buf[pos..], "\",\"items\":[");

    const items_count = prng.range_inclusive(usize, 0, message.order_items_max + 2);
    for (0..items_count) |i| {
        if (i > 0) pos += copy(buf[pos..], ",");
        if (pos + 80 > buf.len) break; // don't overflow

        pos += copy(buf[pos..], "{\"product_id\":\"");
        const pid = gen_uuid_string(prng);
        pos += copy(buf[pos..], &pid);
        pos += copy(buf[pos..], "\",\"quantity\":");
        pos += write_random_number(prng, buf[pos..]);
        pos += copy(buf[pos..], "}");
    }

    pos += copy(buf[pos..], "]}");
    return buf[0..pos];
}

fn gen_transfer_json(prng: *PRNG, buf: *[body_buf_max]u8) []const u8 {
    var pos: usize = 0;
    pos += copy(buf[pos..], "{\"quantity\":");
    pos += write_random_number(prng, buf[pos..]);
    pos += copy(buf[pos..], "}");
    return buf[0..pos];
}

fn gen_mutated_json(prng: *PRNG, buf: *[body_buf_max]u8) []const u8 {
    const base = gen_valid_json(prng, buf);
    const len = base.len;
    if (len == 0) return base;

    const mutation = prng.int_inclusive(usize, 4);
    switch (mutation) {
        0 => {
            // Flip a random byte.
            const idx = prng.int_inclusive(usize, len - 1);
            buf[idx] ^= prng.bit(u8);
        },
        1 => {
            // Truncate.
            return buf[0..prng.int_inclusive(usize, len - 1)];
        },
        2 => {
            // Remove all closing braces/brackets.
            for (buf[0..len]) |*c| {
                if (c.* == '}' or c.* == ']') c.* = ' ';
            }
        },
        3 => {
            // Replace a quoted value with wrong type.
            if (std.mem.indexOf(u8, buf[0..len], "\":\"")) |i| {
                if (i + 3 < len) {
                    buf[i + 2] = '1'; // turn string into number start
                }
            }
        },
        4 => {
            // Inject null bytes.
            const count = prng.range_inclusive(usize, 1, @min(5, len));
            for (0..count) |_| {
                buf[prng.int_inclusive(usize, len - 1)] = 0;
            }
        },
        else => unreachable,
    }
    return buf[0..len];
}

fn gen_random_body(prng: *PRNG, buf: *[body_buf_max]u8) []const u8 {
    const len = prng.range_inclusive(usize, 1, 256);
    prng.fill(buf[0..len]);
    return buf[0..len];
}

// =====================================================================
// Response generation (for encode fuzzer)
// =====================================================================

fn gen_response(prng: *PRNG) message.MessageResponse {
    const status = prng.enum_uniform(message.Status);

    if (status != .ok) {
        return .{ .status = status, .result = .{ .empty = {} } };
    }

    const result_tag = prng.int_inclusive(usize, 7);
    const result: message.Result = switch (result_tag) {
        0 => .{ .product = gen_product(prng) },
        1 => .{ .product_list = gen_product_list(prng) },
        2 => .{ .inventory = prng.int(u32) },
        3 => .{ .collection = gen_collection_with_products(prng) },
        4 => .{ .collection_list = gen_collection_list(prng) },
        5 => .{ .order = gen_order_result(prng) },
        6 => .{ .order_list = gen_order_summary_list(prng) },
        7 => .{ .empty = {} },
        else => unreachable,
    };

    return .{ .status = .ok, .result = result };
}

fn gen_product(prng: *PRNG) message.Product {
    var p = std.mem.zeroes(message.Product);
    p.id = prng.int(u128) | 1;
    p.price_cents = prng.int(u32);
    p.inventory = prng.int(u32);
    p.version = prng.int(u32);
    p.flags = .{ .active = prng.boolean() };
    p.name_len = prng.range_inclusive(u8, 1, message.product_name_max);
    for (p.name[0..p.name_len]) |*c| {
        // Include chars that need JSON escaping.
        c.* = gen_json_char(prng);
    }
    p.description_len = prng.range_inclusive(u16, 0, message.product_description_max);
    for (p.description[0..p.description_len]) |*c| {
        c.* = gen_json_char(prng);
    }
    return p;
}

fn gen_product_list(prng: *PRNG) message.ProductList {
    // Cap at list_max. The encoder must handle a full page, but max-length
    // names with escapable chars can exceed send_buf_max, so we limit list
    // length when product sizes are large (matching real-world constraints —
    // the server stores bounded products).
    var list: message.ProductList = .{
        .items = undefined,
        .len = prng.range_inclusive(u32, 0, message.list_max),
    };
    for (list.items[0..list.len]) |*p| {
        p.* = gen_product(prng);
    }
    // Estimate output size and trim to fit send buffer.
    // Worst case per product: ~1400 bytes (max name + desc with 2x escape expansion).
    const max_safe_items = http.response_body_max / 1400;
    if (list.len > max_safe_items) list.len = max_safe_items;
    return list;
}

fn gen_collection_with_products(prng: *PRNG) message.CollectionWithProducts {
    var col = std.mem.zeroes(message.ProductCollection);
    col.id = prng.int(u128) | 1;
    col.name_len = prng.range_inclusive(u8, 1, message.collection_name_max);
    for (col.name[0..col.name_len]) |*c| {
        c.* = gen_json_char(prng);
    }
    var products = gen_product_list(prng);
    // Keep product list short to avoid buffer overflow in encoder.
    if (products.len > 10) products.len = 10;
    return .{
        .collection = col,
        .products = products,
    };
}

fn gen_collection_list(prng: *PRNG) message.CollectionList {
    var list: message.CollectionList = .{
        .items = undefined,
        .len = prng.range_inclusive(u32, 0, message.list_max),
    };
    for (list.items[0..list.len]) |*col| {
        col.* = std.mem.zeroes(message.ProductCollection);
        col.id = prng.int(u128) | 1;
        col.name_len = prng.range_inclusive(u8, 1, message.collection_name_max);
        for (col.name[0..col.name_len]) |*c| {
            c.* = gen_json_char(prng);
        }
    }
    // Cap to fit send buffer: ~300 bytes per collection worst case.
    const max_safe_items = http.response_body_max / 300;
    if (list.len > max_safe_items) list.len = max_safe_items;
    return list;
}

fn gen_order_result(prng: *PRNG) message.OrderResult {
    var order = std.mem.zeroes(message.OrderResult);
    order.id = prng.int(u128) | 1;
    order.items_len = prng.range_inclusive(u8, 1, message.order_items_max);
    order.total_cents = prng.int(u64);
    for (order.items[0..order.items_len]) |*item| {
        item.* = std.mem.zeroes(message.OrderResultItem);
        item.product_id = prng.int(u128) | 1;
        item.quantity = prng.range_inclusive(u32, 1, 10_000);
        item.price_cents = prng.int(u32);
        item.line_total_cents = prng.int(u64);
        item.name_len = prng.range_inclusive(u8, 1, message.product_name_max);
        for (item.name[0..item.name_len]) |*c| {
            c.* = gen_json_char(prng);
        }
    }
    return order;
}

fn gen_order_summary_list(prng: *PRNG) message.OrderSummaryList {
    var list: message.OrderSummaryList = .{
        .items = undefined,
        .len = prng.range_inclusive(u32, 0, message.list_max),
    };
    for (list.items[0..list.len]) |*o| {
        o.* = std.mem.zeroes(message.OrderSummary);
        o.id = prng.int(u128) | 1;
        o.total_cents = prng.int(u64);
        o.items_len = prng.range_inclusive(u8, 1, message.order_items_max);
    }
    return list;
}

// =====================================================================
// Helpers
// =====================================================================

/// Generate a character suitable for name/description fields.
/// Occasionally produces chars that need JSON escaping.
fn gen_json_char(prng: *PRNG) u8 {
    if (prng.chance(PRNG.ratio(1, 20))) {
        // Escapable characters.
        const escapable = [_]u8{ '"', '\\', '\n', '\r', '\t' };
        return escapable[prng.int_inclusive(usize, escapable.len - 1)];
    }
    // Printable ASCII.
    return prng.range_inclusive(u8, 0x20, 0x7e);
}

fn gen_uuid_string(prng: *PRNG) [32]u8 {
    const strategy = prng.chances(.{
        .valid = 6,
        .nil = 1,
        .all_f = 1,
        .garbage = 2,
    });

    var buf: [32]u8 = undefined;
    const hex = "0123456789abcdef";

    switch (strategy) {
        .valid => {
            for (&buf) |*c| {
                c.* = hex[prng.int_inclusive(usize, 15)];
            }
        },
        .nil => {
            @memset(&buf, '0');
        },
        .all_f => {
            @memset(&buf, 'f');
        },
        .garbage => {
            for (&buf) |*c| {
                c.* = prng.int(u8);
            }
        },
    }
    return buf;
}

fn write_random_number(prng: *PRNG, buf: []u8) usize {
    if (buf.len < 1) return 0;

    // Bias towards interesting values.
    const val: u32 = if (prng.chance(PRNG.ratio(3, 10)))
        prng.int(u32)
    else switch (prng.int_inclusive(usize, 3)) {
        0 => 0,
        1 => 1,
        2 => math.maxInt(u32),
        3 => prng.range_inclusive(u32, 1, 10_000),
        else => unreachable,
    };

    var num_buf: [10]u8 = undefined;
    var v = val;
    var pos: usize = 10;
    if (v == 0) {
        pos -= 1;
        num_buf[pos] = '0';
    } else {
        while (v > 0) {
            pos -= 1;
            num_buf[pos] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
        }
    }
    const s = num_buf[pos..10];
    const copy_len = @min(s.len, buf.len);
    @memcpy(buf[0..copy_len], s[0..copy_len]);
    return copy_len;
}

fn copy(dst: []u8, src: []const u8) usize {
    const len = @min(src.len, dst.len);
    @memcpy(dst[0..len], src[0..len]);
    return len;
}
