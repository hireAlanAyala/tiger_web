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
        const is_datastar_request = prng.boolean();
        const resp = gen_response(&prng);

        const len = render.encode_response(&send_buf, resp, is_datastar_request);

        // Core invariants.
        assert(len > 0);
        assert(len <= send_buf.len);

        const output = send_buf[0..len];

        // Must start with HTTP response line.
        assert(std.mem.startsWith(u8, output, "HTTP/1.1 "));

        if (resp.status != .ok) {
            error_count += 1;
        } else if (is_datastar_request) {
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

fn gen_response(prng: *PRNG) message.MessageResponse {
    // Sometimes generate error responses.
    if (prng.chance(PRNG.ratio(2, 10))) {
        const status = prng.enum_uniform(message.Status);
        if (status != .ok) {
            return .{ .status = status, .result = .{ .empty = {} } };
        }
    }

    return .{
        .status = .ok,
        .result = .{ .page_load_dashboard = .{
            .products = gen_product_list(prng),
            .collections = gen_collection_list(prng),
            .orders = gen_order_summary_list(prng),
        } },
    };
}

fn gen_product_list(prng: *PRNG) message.ProductList {
    var list: message.ProductList = .{
        .items = undefined,
        // Dashboard lists are capped by the state machine to dashboard_list_max.
        .len = prng.range_inclusive(u32, 0, message.dashboard_list_max),
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

fn gen_collection_list(prng: *PRNG) message.CollectionList {
    var list: message.CollectionList = .{
        .items = undefined,
        .len = prng.range_inclusive(u32, 0, message.dashboard_list_max),
    };
    for (list.items[0..list.len]) |*col| {
        col.* = std.mem.zeroes(message.ProductCollection);
        col.id = prng.int(u128) | 1;
        col.name_len = prng.range_inclusive(u8, 1, message.collection_name_max);
        for (col.name[0..col.name_len]) |*c| {
            c.* = gen_html_char(prng);
        }
    }
    return list;
}

fn gen_order_summary_list(prng: *PRNG) message.OrderSummaryList {
    var list: message.OrderSummaryList = .{
        .items = undefined,
        .len = prng.range_inclusive(u32, 0, message.dashboard_list_max),
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
