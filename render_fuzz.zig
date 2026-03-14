//! Render fuzzer — generates random PageLoadDashboardResult values and
//! calls render.encode_response with random is_datastar_request flags.
//!
//! Asserts: output length > 0, output length <= send_buf_max, proper framing prefix.
//!
//! Follows TigerBeetle's fuzz pattern: library called by fuzz_tests.zig dispatcher.

const std = @import("std");
const assert = std.debug.assert;
const render = @import("render.zig");
const http = @import("http.zig");
const message = @import("message.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const PRNG = @import("prng.zig");

const log = std.log.scoped(.fuzz);

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    _ = allocator;

    const seed = args.seed;
    const events_max = args.events_max orelse 50_000;
    var prng = PRNG.from_seed(seed);

    var full_page_count: u64 = 0;
    var sse_count: u64 = 0;
    var error_count: u64 = 0;

    for (0..events_max) |event_i| {
        log.debug("Running render_fuzz[{}/{}]", .{ event_i, events_max });

        var send_buf: [http.send_buf_max]u8 = undefined;
        const gen = gen_response(&prng);

        const len = render.encode_response(&send_buf, gen.operation, gen.resp, gen.is_datastar_request);

        // Core invariants.
        assert(len > 0);
        assert(len <= send_buf.len);

        const output = send_buf[0..len];

        // Must start with HTTP response line.
        assert(std.mem.startsWith(u8, output, "HTTP/1.1 "));

        if (gen.resp.status != .ok) {
            error_count += 1;
        } else if (gen.is_datastar_request or gen.operation != .page_load_dashboard) {
            assert(std.mem.indexOf(u8, output, "text/event-stream") != null);
            assert(std.mem.indexOf(u8, output, "event: datastar-patch-elements") != null);
            assert_sse_framing(output);
            sse_count += 1;
        } else {
            assert(std.mem.indexOf(u8, output, "<!DOCTYPE html>") != null);
            full_page_count += 1;
        }
    }

    log.info(
        \\Render fuzz done:
        \\  events_max={}
        \\  full_page={} sse={} error={}
    , .{ events_max, full_page_count, sse_count, error_count });
}

// =====================================================================
// Response generation
// =====================================================================

const GenResult = struct {
    operation: message.Operation,
    resp: message.MessageResponse,
    is_datastar_request: bool,
};

fn gen_response(prng: *PRNG) GenResult {
    // Pick a renderable operation.
    const renderable_ops = [_]message.Operation{
        .page_load_dashboard,
        .list_products,
        .list_collections,
        .list_orders,
        .get_collection,
        .get_order,
    };
    const operation = renderable_ops[prng.int_inclusive(usize, renderable_ops.len - 1)];

    // is_datastar_request: always true for non-dashboard ops (render asserts it).
    const is_datastar_request = if (operation != .page_load_dashboard) true else prng.boolean();

    // Sometimes generate error responses.
    if (prng.chance(PRNG.ratio(2, 10))) {
        const status = prng.enum_uniform(message.Status);
        if (status != .ok) {
            return .{
                .operation = operation,
                .resp = .{ .status = status, .result = .{ .empty = {} } },
                .is_datastar_request = is_datastar_request,
            };
        }
    }

    const resp: message.MessageResponse = switch (operation) {
        .page_load_dashboard => .{
            .status = .ok,
            .result = .{ .page_load_dashboard = .{
                .products = gen_product_list(prng, message.dashboard_list_max),
                .collections = gen_collection_list(prng, message.dashboard_list_max),
                .orders = gen_order_summary_list(prng, message.dashboard_list_max),
            } },
        },
        .list_products => .{
            .status = .ok,
            .result = .{ .product_list = gen_product_list(prng, message.list_max) },
        },
        .list_collections => .{
            .status = .ok,
            .result = .{ .collection_list = gen_collection_list(prng, message.list_max) },
        },
        .list_orders => .{
            .status = .ok,
            .result = .{ .order_list = gen_order_summary_list(prng, message.list_max) },
        },
        .get_collection => .{
            .status = .ok,
            .result = .{ .collection = gen_collection_with_products(prng) },
        },
        .get_order => .{
            .status = .ok,
            .result = .{ .order = gen_order_result(prng) },
        },
        else => unreachable,
    };

    return .{
        .operation = operation,
        .resp = resp,
        .is_datastar_request = is_datastar_request,
    };
}

fn gen_product_list(prng: *PRNG, max_len: u32) message.ProductList {
    var list: message.ProductList = .{
        .items = undefined,
        .len = prng.range_inclusive(u32, 0, max_len),
    };
    for (list.items[0..list.len]) |*p| {
        p.* = gen_product(prng);
    }
    return list;
}

fn gen_product(prng: *PRNG) message.Product {
    var p = std.mem.zeroes(message.Product);
    p.id = prng.int(u128) | 1;
    p.price_cents = prng.range_inclusive(u32, 0, 999999);
    p.inventory = prng.range_inclusive(u32, 0, 10000);
    p.version = prng.range_inclusive(u32, 1, 100);
    p.flags = .{ .active = prng.boolean() };
    p.name_len = prng.range_inclusive(u8, 1, message.product_name_max);
    for (p.name[0..p.name_len]) |*c| {
        c.* = gen_html_char(prng);
    }
    p.description_len = prng.range_inclusive(u16, 0, message.product_description_max);
    for (p.description[0..p.description_len]) |*c| {
        c.* = gen_html_char(prng);
    }
    return p;
}

fn gen_collection(prng: *PRNG) message.ProductCollection {
    var col = std.mem.zeroes(message.ProductCollection);
    col.id = prng.int(u128) | 1;
    col.name_len = prng.range_inclusive(u8, 1, message.collection_name_max);
    for (col.name[0..col.name_len]) |*c| {
        c.* = gen_html_char(prng);
    }
    return col;
}

fn gen_collection_list(prng: *PRNG, max_len: u32) message.CollectionList {
    var list: message.CollectionList = .{
        .items = undefined,
        .len = prng.range_inclusive(u32, 0, max_len),
    };
    for (list.items[0..list.len]) |*col| {
        col.* = gen_collection(prng);
    }
    return list;
}

fn gen_order_summary_list(prng: *PRNG, max_len: u32) message.OrderSummaryList {
    var list: message.OrderSummaryList = .{
        .items = undefined,
        .len = prng.range_inclusive(u32, 0, max_len),
    };
    for (list.items[0..list.len]) |*o| {
        o.* = std.mem.zeroes(message.OrderSummary);
        o.id = prng.int(u128) | 1;
        o.total_cents = prng.int(u64);
        o.items_len = prng.range_inclusive(u8, 1, message.order_items_max);
        o.status = prng.enum_uniform(message.OrderStatus);
    }
    return list;
}

fn gen_collection_with_products(prng: *PRNG) message.CollectionWithProducts {
    return .{
        .collection = gen_collection(prng),
        .products = gen_product_list(prng, message.list_max),
    };
}

fn gen_order_result(prng: *PRNG) message.OrderResult {
    var order = std.mem.zeroes(message.OrderResult);
    order.id = prng.int(u128) | 1;
    order.total_cents = prng.int(u64);
    order.status = prng.enum_uniform(message.OrderStatus);
    order.items_len = prng.range_inclusive(u8, 0, message.order_items_max);
    for (order.items[0..order.items_len]) |*item| {
        item.* = std.mem.zeroes(message.OrderResultItem);
        item.product_id = prng.int(u128) | 1;
        item.price_cents = prng.range_inclusive(u32, 0, 999999);
        item.quantity = prng.range_inclusive(u32, 1, 100);
        item.line_total_cents = @as(u64, item.price_cents) * @as(u64, item.quantity);
        item.name_len = prng.range_inclusive(u8, 1, message.product_name_max);
        for (item.name[0..item.name_len]) |*c| {
            c.* = gen_html_char(prng);
        }
    }
    return order;
}

/// Assert valid SSE framing: after the HTTP headers, every non-empty line
/// must start with "event:" or "data:". A bare line (no prefix) inside an
/// event would break the SSE protocol.
fn assert_sse_framing(output: []const u8) void {
    // Skip past HTTP headers (end at \r\n\r\n).
    const header_end = std.mem.indexOf(u8, output, "\r\n\r\n") orelse return;
    const body = output[header_end + 4 ..];

    var iter = std.mem.splitScalar(u8, body, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue; // empty line = event separator, valid
        if (std.mem.startsWith(u8, line, "event:")) continue;
        if (std.mem.startsWith(u8, line, "data:")) continue;
        // Bare \r from \r\n split is fine (SSE uses \n, not \r\n for body).
        if (line.len == 1 and line[0] == '\r') continue;
        std.debug.panic("invalid SSE line: '{s}' (len={})", .{ line[0..@min(line.len, 80)], line.len });
    }
}

/// Generate a character that exercises HTML/JS escaping paths.
/// Includes control characters (newlines, tabs) that js_escaped must handle.
fn gen_html_char(prng: *PRNG) u8 {
    if (prng.chance(PRNG.ratio(1, 10))) {
        const escapable = [_]u8{ '<', '>', '&', '"', '\'', '\\', '\n', '\r', '\t', 0x01 };
        return escapable[prng.int_inclusive(usize, escapable.len - 1)];
    }
    return prng.range_inclusive(u8, 0x20, 0x7e);
}
