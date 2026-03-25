//! Sidecar wire protocol — JSON length-prefixed messages between the Zig
//! framework and the TypeScript sidecar over a unix socket.
//!
//! Wire format: [4-byte big-endian length][JSON payload]
//!
//! Three message exchanges per HTTP request:
//!   1. Route:     framework sends route_request → sidecar sends route_response
//!   2. Execute:   framework sends execute_request
//!      → sidecar sends prefetch_queries
//!      → framework executes SQL, sends prefetch_results
//!      → sidecar sends handle_render_result (status + writes + html)
//!
//! All data is JSON — no binary serde, no extern structs, no padding.
//! PrefetchCache, WriteTag, WriteSlot are dead. SQL strings travel the wire.

const std = @import("std");
const assert = std.debug.assert;

/// Maximum frame payload size (JSON bytes). 1 MB should handle any response.
pub const frame_max = 1024 * 1024;

const message = @import("message.zig");

/// Maximum number of write SQL statements from a single handle() call.
/// Derived from the domain constant — sidecar cannot exceed what the SM accepts.
pub const writes_max = message.writes_max;

comptime {
    assert(writes_max > 0);
}

/// Maximum SQL string length in a single query/write.
pub const sql_max = 4096;

/// Maximum number of prefetch queries from a single prefetch() call.
pub const prefetch_queries_max = 32;

/// Read a length-prefixed JSON frame from fd into buf.
/// Returns the JSON slice, or null on EOF/error.
/// buf must be at least frame_max + 4 bytes.
pub fn read_frame(fd: std.posix.fd_t, buf: []u8) ?[]const u8 {
    assert(buf.len >= frame_max + 4);

    // Read 4-byte big-endian length.
    var header: [4]u8 = undefined;
    if (!recv_exact(fd, &header)) return null;

    const len = std.mem.readInt(u32, &header, .big);
    if (len == 0) return "";
    if (len > frame_max) return null;

    // Read payload.
    if (!recv_exact(fd, buf[0..len])) return null;
    return buf[0..len];
}

/// Write a length-prefixed JSON frame to fd.
/// Returns false on error.
pub fn write_frame(fd: std.posix.fd_t, json: []const u8) bool {
    assert(json.len <= frame_max);

    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(json.len), .big);

    if (!send_exact(fd, &header)) return false;
    if (json.len > 0) {
        if (!send_exact(fd, json)) return false;
    }
    return true;
}

// --- IO helpers ---

fn recv_exact(fd: std.posix.fd_t, buf: []u8) bool {
    var recvd: usize = 0;
    while (recvd < buf.len) {
        const n = std.posix.recv(fd, buf[recvd..], 0) catch return false;
        if (n == 0) return false; // peer closed
        recvd += n;
    }
    return true;
}

fn send_exact(fd: std.posix.fd_t, bytes: []const u8) bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = std.posix.send(fd, bytes[sent..], std.posix.MSG.NOSIGNAL) catch return false;
        if (n == 0) return false;
        sent += n;
    }
    return true;
}

// =====================================================================
// Tests
// =====================================================================

test "frame round trip" {
    const pair = test_socketpair();
    defer std.posix.close(pair[1]);

    const json = "{\"tag\":\"route\",\"method\":\"GET\",\"path\":\"/products\"}";

    // Write frame.
    try std.testing.expect(write_frame(pair[0], json));

    // Read frame.
    var buf: [frame_max + 4]u8 = undefined;
    const result = read_frame(pair[1], &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(json, result.?);
    std.posix.close(pair[0]);
}

test "empty frame" {
    const pair = test_socketpair();
    defer std.posix.close(pair[1]);

    try std.testing.expect(write_frame(pair[0], ""));

    var buf: [frame_max + 4]u8 = undefined;
    const result = read_frame(pair[1], &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?);
    std.posix.close(pair[0]);
}

test "peer closed returns null" {
    const pair = test_socketpair();
    std.posix.close(pair[0]);

    var buf: [frame_max + 4]u8 = undefined;
    const result = read_frame(pair[1], &buf);
    try std.testing.expect(result == null);
    std.posix.close(pair[1]);
}

fn test_socketpair() [2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    assert(rc == 0);
    return fds;
}
