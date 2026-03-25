//! Sidecar protocol fuzzer — stub for the new JSON protocol.
//!
//! The old fuzzer tested binary protocol corruption (random bytes in
//! TranslateResponse, ExecuteRenderResponse). The new JSON protocol
//! needs a different fuzzing strategy: malformed JSON frames,
//! truncated frames, invalid field values.
//!
//! TODO: Rebuild for JSON length-prefixed protocol.
//!
//! Follows TigerBeetle's fuzz pattern: library called by fuzz_tests.zig dispatcher.

const std = @import("std");
const assert = std.debug.assert;
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const PRNG = @import("tiger_framework").prng;
const protocol = @import("protocol.zig");

const log = std.log.scoped(.fuzz);

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    _ = allocator;
    const seed = args.seed;
    const events_max = args.events_max orelse 10_000;
    var prng = PRNG.from_seed(seed);

    // Stub: exercise the JSON frame helpers.
    for (0..events_max) |_| {
        var fds: [2]std.posix.fd_t = undefined;
        const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
        if (rc != 0) continue;

        // Generate random JSON-like frame.
        var json_buf: [1024]u8 = undefined;
        const len = prng.range_inclusive(usize, 0, json_buf.len);
        prng.fill(json_buf[0..len]);

        const ok = protocol.write_frame(fds[0], json_buf[0..len]);
        if (ok) {
            var recv_buf: [protocol.frame_max + 4]u8 = undefined;
            _ = protocol.read_frame(fds[1], &recv_buf);
        }

        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    log.info("Sidecar JSON fuzz done: events_max={}", .{events_max});
}
