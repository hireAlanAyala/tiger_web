const std = @import("std");
const log = std.log.scoped(.worker);

/// Worker process — polls the server for pending orders, simulates an
/// external API call, and posts the completion back. Deliberately dumb:
/// no business logic, no state machine knowledge. Just HTTP client ↔
/// external service ↔ HTTP client.
///
/// Usage:
///   TOKEN=<jwt> ./zig/zig build run-worker
///   ./zig/zig build run-worker -- --port=3001 --delay-ms=2000

pub fn main() !void {
    const cli = parse_cli();

    log.info("worker starting: server=http://127.0.0.1:{d} poll_interval={d}ms external_delay={d}ms", .{
        cli.port,
        cli.poll_interval_ms,
        cli.delay_ms,
    });

    if (cli.token.len == 0) {
        log.err("TOKEN not set", .{});
        std.process.exit(1);
    }

    var poll_count: u64 = 0;
    var completed_count: u64 = 0;

    while (true) {
        poll_count += 1;

        const pending = fetch_pending_orders(cli.port, cli.token) catch |err| {
            log.warn("poll failed: {s}", .{@errorName(err)});
            std.time.sleep(cli.poll_interval_ms * std.time.ns_per_ms);
            continue;
        };

        if (pending.count > 0) {
            log.info("poll #{d}: found {d} pending orders", .{ poll_count, pending.count });

            for (pending.ids[0..pending.count]) |order_id| {
                // Simulate external API call (e.g., Stripe charge).
                log.info("processing order {s}... (simulating {d}ms external call)", .{
                    format_uuid(order_id),
                    cli.delay_ms,
                });
                std.time.sleep(cli.delay_ms * std.time.ns_per_ms);

                // External call "succeeded" — post completion.
                const result: []const u8 = "confirmed";
                post_completion(cli.port, cli.token, order_id, result) catch |err| {
                    log.warn("completion failed for {s}: {s}", .{
                        format_uuid(order_id),
                        @errorName(err),
                    });
                    continue;
                };

                completed_count += 1;
                log.info("completed order {s} ({s}), total completed: {d}", .{
                    format_uuid(order_id),
                    result,
                    completed_count,
                });
            }
        } else {
            if (poll_count % 10 == 0) {
                log.debug("poll #{d}: no pending orders", .{poll_count});
            }
        }

        std.time.sleep(cli.poll_interval_ms * std.time.ns_per_ms);
    }
}

// =====================================================================
// HTTP client — minimal, no allocations, fixed-size buffers
// =====================================================================

const max_orders = 50;

const PendingOrders = struct {
    ids: [max_orders][32]u8,
    count: usize,
};

fn fetch_pending_orders(port: u16, token: []const u8) !PendingOrders {
    var result = PendingOrders{ .ids = undefined, .count = 0 };

    var buf: [16384]u8 = undefined;
    const response = try http_get(port, "/orders", token, &buf);

    // Parse order IDs from JSON response. Look for "status":"pending" entries.
    var pos: usize = 0;
    while (pos < response.len and result.count < max_orders) {
        // Find next "id":"
        const id_key = std.mem.indexOfPos(u8, response, pos, "\"id\":\"") orelse break;
        const id_start = id_key + 6;
        const id_end = std.mem.indexOfPos(u8, response, id_start, "\"") orelse break;
        const id_str = response[id_start..id_end];

        // Check if this order has "status":"pending"
        const next_obj_end = std.mem.indexOfPos(u8, response, id_end, "}") orelse break;
        const obj_slice = response[id_key..next_obj_end];

        if (std.mem.indexOf(u8, obj_slice, "\"status\":\"pending\"") != null) {
            if (id_str.len == 32) {
                @memcpy(&result.ids[result.count], id_str);
                result.count += 1;
            }
        }

        pos = next_obj_end + 1;
    }

    return result;
}

fn post_completion(port: u16, token: []const u8, order_id: [32]u8, completion_result: []const u8) !void {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/orders/{s}/complete", .{order_id}) catch unreachable;

    var body_buf: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"result\":\"{s}\"}}", .{completion_result}) catch unreachable;

    var buf: [4096]u8 = undefined;
    _ = try http_post(port, path, token, body, &buf);
}

fn http_get(port: u16, path: []const u8, token: []const u8, buf: []u8) ![]const u8 {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const stream = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(stream);

    try std.posix.connect(stream, &addr.any, addr.getOsSockLen());

    // Build request.
    var req_buf: [2048]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAuthorization: Bearer {s}\r\nConnection: close\r\n\r\n", .{ path, port, token }) catch unreachable;

    _ = try std.posix.write(stream, req);

    // Read response.
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(stream, buf[total..]) catch |err| switch (err) {
            error.ConnectionResetByPeer => break,
            else => return err,
        };
        if (n == 0) break;
        total += n;
    }

    // Find body (after \r\n\r\n).
    const header_end = std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") orelse return buf[0..0];
    return buf[header_end + 4 .. total];
}

fn http_post(port: u16, path: []const u8, token: []const u8, body: []const u8, buf: []u8) ![]const u8 {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const stream = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(stream);

    try std.posix.connect(stream, &addr.any, addr.getOsSockLen());

    var req_buf: [2048]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "POST {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ path, port, token, body.len, body }) catch unreachable;

    _ = try std.posix.write(stream, req);

    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(stream, buf[total..]) catch |err| switch (err) {
            error.ConnectionResetByPeer => break,
            else => return err,
        };
        if (n == 0) break;
        total += n;
    }

    const header_end = std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") orelse return buf[0..0];
    return buf[header_end + 4 .. total];
}

fn format_uuid(hex: [32]u8) [36]u8 {
    var out: [36]u8 = undefined;
    var o: usize = 0;
    for (hex, 0..) |c, i| {
        if (i == 8 or i == 12 or i == 16 or i == 20) {
            out[o] = '-';
            o += 1;
        }
        out[o] = c;
        o += 1;
    }
    return out;
}

// =====================================================================
// CLI
// =====================================================================

const Cli = struct {
    port: u16,
    poll_interval_ms: u64,
    delay_ms: u64,
    token: []const u8,
};

fn parse_cli() Cli {
    var result = Cli{
        .port = 3000,
        .poll_interval_ms = 2000,
        .delay_ms = 3000,
        .token = std.posix.getenv("TOKEN") orelse "",
    };

    var args = std.process.args();
    _ = args.skip(); // program name

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            const val = arg["--port=".len..];
            result.port = std.fmt.parseInt(u16, val, 10) catch 3000;
        } else if (std.mem.startsWith(u8, arg, "--poll-ms=")) {
            const val = arg["--poll-ms=".len..];
            result.poll_interval_ms = std.fmt.parseInt(u64, val, 10) catch 2000;
        } else if (std.mem.startsWith(u8, arg, "--delay-ms=")) {
            const val = arg["--delay-ms=".len..];
            result.delay_ms = std.fmt.parseInt(u64, val, 10) catch 3000;
        }
    }

    return result;
}
