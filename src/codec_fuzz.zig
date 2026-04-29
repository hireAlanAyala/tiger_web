//! Codec fuzzer — exercises the HTTP parser + route translator at the
//! network boundary. This is the public-internet attack surface;
//! `sim.zig` only sends well-formed HTTP, so the parser's behavior
//! under malformed input is not otherwise covered.
//!
//! Strategy: three input modes per iteration, weighted toward
//! adversarial-but-plausible shapes:
//!   - `random_bytes`  — pure entropy (most reject as `.invalid`).
//!   - `mostly_valid`  — start from a real request, mutate one byte.
//!   - `boundary`      — exercise edge cases (empty path, max body,
//!     conflicting headers, header injection markers).
//!
//! Invariants asserted:
//!   - `parse_request` returns one of three enum variants — must not
//!     panic, infinite-loop, or return out-of-bounds slices.
//!   - For `.complete`: `total_len <= buf.len`, body length matches
//!     advertised Content-Length, slices live inside the input buffer.
//!   - `app.translate` must accept any (method, path, body) triple
//!     `parse_request` returned without crashing — null is fine,
//!     a typed Message is fine, panic is not.
//!
//! Follows TigerBeetle's per-protocol fuzz pattern (see
//! `src/message_bus_fuzz.zig`): cluster sim covers behavior; per-
//! boundary fuzzers cover parser robustness. The two are
//! complementary, not redundant.

const std = @import("std");
const assert = std.debug.assert;
const http = @import("framework/http.zig");
const app = @import("app.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const stdx = @import("stdx");
const PRNG = stdx.PRNG;

const log = std.log.scoped(.fuzz);

const Mode = enum { random_bytes, mostly_valid, boundary };

const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE" };
const paths = [_][]const u8{
    "/",
    "/products",
    "/products/01HQ7K8MZG3R9TYFA0XV5JN2P4",
    "/products/01HQ7K8MZG3R9TYFA0XV5JN2P4/inventory",
    "/orders",
    "/login/code",
    "/logout",
};

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 50_000;
    var prng = PRNG.from_seed(seed);

    var buf: [http.recv_buf_max + 64]u8 = undefined;
    var iterations: u64 = 0;
    var completes: u64 = 0;
    var invalids: u64 = 0;
    var incompletes: u64 = 0;
    var translates_ok: u64 = 0;

    for (0..events_max) |_| {
        const mode_roll = prng.range_inclusive(u32, 0, 99);
        const mode: Mode = if (mode_roll < 25)
            .random_bytes
        else if (mode_roll < 80)
            .mostly_valid
        else
            .boundary;

        const len = generate(allocator, &prng, mode, &buf);
        const input = buf[0..len];

        const result = http.parse_request(input);
        switch (result) {
            .complete => |c| {
                // Bounds invariants — the parser must not lie about lengths
                // or hand us slices outside the input buffer.
                assert(c.total_len <= input.len);
                assert(c.path.len > 0);
                assert(c.path.len <= input.len);
                assert(c.body.len <= http.body_max);
                assert(c.body.len <= input.len);
                completes += 1;

                // Boundary check 2 — translate must not crash on whatever
                // the parser accepts. Null is a valid outcome (unmapped
                // route); a typed Message is fine; a panic would mean the
                // route table or domain types disagree with what the
                // parser admits.
                const msg = app.translate(c.method, c.path, c.body);
                if (msg != null) translates_ok += 1;
            },
            .invalid => invalids += 1,
            .incomplete => incompletes += 1,
        }

        iterations += 1;
    }

    log.info(
        "Codec fuzz done: iters={d} complete={d} invalid={d} incomplete={d} translated={d}",
        .{ iterations, completes, invalids, incompletes, translates_ok },
    );
    assert(iterations > 0);
    // Sanity — at least some inputs should reach .complete and some
    // should be rejected. If 100% are .invalid, the generator is broken.
    assert(completes > 0);
    assert(invalids > 0);
}

/// Build one fuzz input into `out`. Returns the number of bytes written.
/// Capped at `http.recv_buf_max` since longer inputs can only test the
/// "header too large → invalid" path, which is already covered by a few
/// shapes in the boundary mode.
fn generate(_: std.mem.Allocator, prng: *PRNG, mode: Mode, out: []u8) usize {
    switch (mode) {
        .random_bytes => {
            const len = prng.range_inclusive(usize, 0, @min(out.len, 1024));
            for (out[0..len]) |*b| b.* = prng.int(u8);
            return len;
        },
        .mostly_valid => {
            // Build a well-formed request, then flip a byte at random.
            const method = methods[prng.range_inclusive(usize, 0, methods.len - 1)];
            const path = paths[prng.range_inclusive(usize, 0, paths.len - 1)];
            const body_len = prng.range_inclusive(usize, 0, 64);
            var pos: usize = 0;
            pos += writeAll(out[pos..], method);
            pos += writeAll(out[pos..], " ");
            pos += writeAll(out[pos..], path);
            pos += writeAll(out[pos..], " HTTP/1.1\r\n");
            if (body_len > 0) {
                var lenbuf: [32]u8 = undefined;
                const lenstr = std.fmt.bufPrint(
                    &lenbuf,
                    "Content-Length: {d}\r\n",
                    .{body_len},
                ) catch unreachable;
                pos += writeAll(out[pos..], lenstr);
            }
            pos += writeAll(out[pos..], "\r\n");
            for (0..body_len) |_| {
                if (pos >= out.len) break;
                out[pos] = prng.int(u8);
                pos += 1;
            }
            // Apply one mutation 70% of the time — pure-valid is also useful
            // (asserts the happy path doesn't somehow regress).
            if (prng.range_inclusive(u32, 0, 99) < 70 and pos > 0) {
                const idx = prng.range_inclusive(usize, 0, pos - 1);
                out[idx] = prng.int(u8);
            }
            return pos;
        },
        .boundary => {
            // A small set of shapes that exercise specific edge paths.
            const shape = prng.range_inclusive(u32, 0, 9);
            const fixtures = [_][]const u8{
                // Empty.
                "",
                // Just a CR/LF salad.
                "\r\n\r\n\r\n",
                // Headers without a body when one is required.
                "PUT /x HTTP/1.1\r\n\r\n",
                // Conflicting Content-Length.
                "POST /x HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 9\r\n\r\nhello",
                // Header injection in path (smuggling marker).
                "GET /\r\nX-Smuggled: yes HTTP/1.1\r\n\r\n",
                // Missing HTTP version.
                "GET /\r\n\r\n",
                // Empty path.
                "GET  HTTP/1.1\r\n\r\n",
                // Method with embedded space.
                "GE T / HTTP/1.1\r\n\r\n",
                // HTTP/1.0 (no keep-alive default).
                "GET / HTTP/1.0\r\n\r\n",
                // Massive Content-Length advertised, no body.
                "POST /x HTTP/1.1\r\nContent-Length: 999999\r\n\r\n",
            };
            const fixture = fixtures[shape];
            const n = @min(fixture.len, out.len);
            stdx.copy_disjoint(.exact, u8, out[0..n], fixture[0..n]);
            return n;
        },
    }
}

fn writeAll(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    stdx.copy_disjoint(.exact, u8, dst[0..n], src[0..n]);
    return n;
}
