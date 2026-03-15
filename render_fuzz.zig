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
    var followup_count: u64 = 0;
    var unauth_count: u64 = 0;
    var error_count: u64 = 0;

    for (0..events_max) |event_i| {
        log.debug("Running render_fuzz[{}/{}]", .{ event_i, events_max });

        var send_buf: [http.send_buf_max]u8 = undefined;

        // ~5% of events exercise the auth failure path.
        if (prng.chance(PRNG.ratio(1, 20))) {
            const is_datastar = prng.boolean();
            const resp = render.encode_unauthorized(&send_buf, is_datastar);
            assert(resp.len > 0);
            assert(resp.offset + resp.len <= send_buf.len);
            const output = send_buf[resp.offset..][0..resp.len];
            assert(std.mem.startsWith(u8, output, "HTTP/1.1 200 OK\r\n"));
            if (is_datastar) {
                assert(!resp.keep_alive);
                assert(std.mem.indexOf(u8, output, "text/event-stream") != null);
                assert(std.mem.indexOf(u8, output, "Unauthorized") != null);
                assert_sse_framing(output);
            } else {
                assert(resp.keep_alive);
                assert(std.mem.indexOf(u8, output, "<!DOCTYPE html>") != null);
                assert(std.mem.indexOf(u8, output, "Content-Length:") != null);
            }
            unauth_count += 1;
            continue;
        }

        const gen = gen_response(&prng);

        // SSE mutations go through encode_followup, not encode_response.
        if (gen.is_datastar_request and render.is_mutation(gen.operation)) {
            const dashboard = message.PageLoadDashboardResult{
                .products = gen_product_list(&prng, message.dashboard_list_max),
                .collections = gen_collection_list(&prng, message.dashboard_list_max),
                .orders = gen_order_summary_list(&prng, message.dashboard_list_max),
            };
            const followup_status = if (gen.resp.status != .ok) gen.resp.status else .ok;
            const resp = render.encode_followup(&send_buf, &dashboard, gen.operation, followup_status);

            assert(resp.len > 0);
            assert(resp.offset + resp.len <= send_buf.len);
            assert(!resp.keep_alive);

            const output = send_buf[resp.offset..][0..resp.len];
            assert(std.mem.startsWith(u8, output, "HTTP/1.1 200 OK\r\n"));
            assert(std.mem.indexOf(u8, output, "text/event-stream") != null);
            // Follow-ups always have dashboard fragments.
            assert(std.mem.indexOf(u8, output, "event: datastar-patch-elements") != null);
            assert_sse_framing(output);

            // Error follow-ups include the status string in the output.
            if (followup_status != .ok) {
                error_count += 1;
            }
            followup_count += 1;
            continue;
        }

        const resp = render.encode_response(&send_buf, gen.operation, gen.resp, gen.is_datastar_request);

        // Core invariants.
        assert(resp.len > 0);
        assert(resp.offset + resp.len <= send_buf.len);

        const output = send_buf[resp.offset..][0..resp.len];

        // Must start with HTTP response line.
        assert(std.mem.startsWith(u8, output, "HTTP/1.1 200 OK\r\n"));

        if (gen.is_datastar_request) {
            assert(!resp.keep_alive);
        }

        if (gen.resp.status != .ok) {
            if (gen.is_datastar_request) {
                // SSE errors: error fragment targeting the operation's panel.
                assert(std.mem.indexOf(u8, output, "text/event-stream") != null);
                assert(std.mem.indexOf(u8, output, "<div class=\"error\">") != null);
                assert_sse_framing(output);
            } else {
                // Non-SSE errors: full dashboard page for recovery.
                assert(std.mem.indexOf(u8, output, "<!DOCTYPE html>") != null);
                assert(std.mem.indexOf(u8, output, "Content-Length:") != null);
                assert(resp.keep_alive);
            }
            error_count += 1;
        } else if (!gen.is_datastar_request and gen.operation == .page_load_dashboard) {
            assert(std.mem.indexOf(u8, output, "<!DOCTYPE html>") != null);
            assert(resp.keep_alive);
            assert(std.mem.indexOf(u8, output, "Content-Length:") != null);
            full_page_count += 1;
        } else if (gen.is_datastar_request) {
            // GETs over SSE: headers + event data.
            assert(std.mem.indexOf(u8, output, "text/event-stream") != null);
            assert(std.mem.indexOf(u8, output, "event: datastar-patch-elements") != null);
            assert_sse_framing(output);
            sse_count += 1;
        } else {
            // Non-Datastar, non-dashboard: HTML response.
            assert(std.mem.indexOf(u8, output, "text/html") != null);
            assert(resp.keep_alive);
            assert(std.mem.indexOf(u8, output, "Content-Length:") != null);
            full_page_count += 1;
        }
    }

    log.info(
        \\Render fuzz done:
        \\  events_max={}
        \\  full_page={} sse={} followup={} unauth={} error={}
    , .{ events_max, full_page_count, sse_count, followup_count, unauth_count, error_count });
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
    // All operations are rendered — pick any.
    const all_ops = [_]message.Operation{
        .page_load_dashboard,
        .list_products,
        .list_collections,
        .list_orders,
        .get_collection,
        .get_order,
        .create_product,
        .update_product,
        .get_product,
        .delete_product,
        .get_product_inventory,
        .transfer_inventory,
        .search_products,
        .create_collection,
        .delete_collection,
        .add_collection_member,
        .remove_collection_member,
        .create_order,
        .complete_order,
        .cancel_order,
    };
    const operation = all_ops[prng.int_inclusive(usize, all_ops.len - 1)];

    const is_datastar_request = prng.boolean();

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
        .get_order, .create_order => .{
            .status = .ok,
            .result = .{ .order = gen_order_result(prng) },
        },
        .create_product, .update_product, .get_product => .{
            .status = .ok,
            .result = .{ .product = gen_product(prng) },
        },
        .get_product_inventory => .{
            .status = .ok,
            .result = .{ .inventory = prng.int(u32) },
        },
        .transfer_inventory => .{
            .status = .ok,
            .result = .{ .product_list = gen_product_list(prng, message.list_max) },
        },
        .create_collection => .{
            .status = .ok,
            .result = .{ .collection = gen_collection_with_products(prng) },
        },
        .complete_order, .cancel_order => .{
            .status = .ok,
            .result = .{ .order = gen_order_result(prng) },
        },
        .search_products => .{
            .status = .ok,
            .result = .{ .product_list = gen_product_list(prng, message.list_max) },
        },
        .delete_product, .delete_collection,
        .add_collection_member, .remove_collection_member,
        => .{
            .status = .ok,
            .result = .{ .empty = {} },
        },
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
