//! Shared memory layout primitives — the wire format common to every
//! SHM transport (shm_bus for sidecar CALL/RESULT, worker_dispatch for
//! background workers).
//!
//! **One source of truth, referenced by name.** Both transports declare
//! their own SlotHeader (they diverge on the trailing byte: shm_bus
//! carries an explicit slot_state enum, worker_dispatch does not), but
//! the shared leading 24 bytes, the RegionHeader, and the CRC convention
//! live here. A header-offset bug once had to be fixed twice — see
//! commit 7fe537e — which is what this module exists to prevent.
//!
//! Pair-assert via `assert_slot_header_layout(T)`: each transport's
//! SlotHeader calls it in a comptime block, which proves the common
//! fields are at the canonical offsets. Offsets match the cross-language
//! contract in packages/vectors/shm_layout.json.
//!
//! TB reference: vsr/checksum.zig — one named primitive, reused by name
//! from every call site. No generic container, no wrapper around the
//! extern struct. Just the substrate.

const std = @import("std");
const assert = std.debug.assert;
const Crc32 = std.hash.crc.Crc32;

/// RegionHeader — 64-byte capacity metadata at the start of every SHM
/// region. Identical layout for every transport. Readers (including the
/// TS sidecar) interpret this header first to learn slot_count and
/// frame_max before mapping the full region.
///
/// Field default policy (deliberately mixed):
///   - `slot_count` and `frame_max` have **no defaults** — they carry
///     semantic meaning per region and must be set explicitly at the
///     call site (TB: "explicitly pass options... instead of relying
///     on the defaults").
///   - `_reserved` and `_pad` **default to zero** — the protocol
///     requires them zero, and mmap'd regions come pre-zeroed by
///     @memset. Defaults match the wire contract.
///
/// This isn't an inconsistency; it's the right behavior per field. The
/// invariant "semantic fields require caller intent, reserved bytes are
/// always zero" is stronger than a blanket all-or-nothing default rule.
pub const RegionHeader = extern struct {
    slot_count: u16,
    _reserved: u16 = 0,
    frame_max: u32,
    _pad: [56]u8 = [_]u8{0} ** 56,

    comptime {
        assert(@sizeOf(@This()) == 64);
        assert(@offsetOf(@This(), "slot_count") == 0);
        assert(@offsetOf(@This(), "_reserved") == 2);
        assert(@offsetOf(@This(), "frame_max") == 4);
        assert(@offsetOf(@This(), "_pad") == 8);
    }
};

/// Assert that a transport-specific SlotHeader places the shared leading
/// fields at the canonical offsets. Every SlotHeader calls this in a
/// comptime block — if the layout drifts, the build fails.
///
/// Offsets are frozen by the cross-language contract in
/// packages/vectors/shm_layout.json. The TS sidecar reads these offsets
/// directly; drifting them silently breaks dispatch.
pub fn assert_slot_header_layout(comptime T: type) void {
    comptime {
        assert(@sizeOf(T) == 64);
        assert(@offsetOf(T, "server_seq") == 0);
        assert(@offsetOf(T, "sidecar_seq") == 4);
        assert(@offsetOf(T, "request_len") == 8);
        assert(@offsetOf(T, "response_len") == 12);
        assert(@offsetOf(T, "request_crc") == 16);
        assert(@offsetOf(T, "response_crc") == 20);
    }
}

/// Compute the CRC32 of a frame: CRC(u32 LE payload_len ++ payload).
///
/// The length-prefix then payload convention is part of the
/// cross-language contract (packages/vectors/shm_layout.json:
/// crc_convention). A corrupted length produces a CRC mismatch rather
/// than a garbage read — matches TB's convention for disk writes.
///
/// `inline` because this is called on every CALL write, every RESULT
/// read, and every worker dispatch — the function body is ~5 instructions
/// plus the Crc32 loop and inlining lets the compiler fold the `len`
/// bytes into the CRC state directly.
pub inline fn crc_frame(len: u32, payload: []const u8) u32 {
    // The caller's buffer must hold at least `len` bytes — otherwise
    // we'd CRC garbage beyond the declared frame.
    assert(payload.len >= len);

    var crc = Crc32.init();
    crc.update(std.mem.asBytes(&len));
    crc.update(payload[0..len]);
    return crc.final();
}

// =====================================================================
// Tests
// =====================================================================

test "RegionHeader size and offsets" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(RegionHeader));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(RegionHeader, "slot_count"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(RegionHeader, "frame_max"));
}

test "crc_frame is a deterministic LE-len ++ payload CRC" {
    // Empty payload: CRC over four zero bytes.
    try std.testing.expectEqual(Crc32.hash(&[_]u8{ 0, 0, 0, 0 }), crc_frame(0, &[_]u8{}));

    // One-byte payload: CRC over 4-byte length ++ payload byte.
    const one = [_]u8{0xAB};
    try std.testing.expectEqual(
        Crc32.hash(&[_]u8{ 1, 0, 0, 0, 0xAB }),
        crc_frame(1, &one),
    );

    // Length prefix matters: same payload, different declared length
    // produces a different CRC (guards against length-forgery).
    const two = [_]u8{ 0xAB, 0xCD };
    const c1 = crc_frame(1, &two);
    const c2 = crc_frame(2, &two);
    try std.testing.expect(c1 != c2);
}

test "assert_slot_header_layout accepts a canonical SlotHeader" {
    // Transport-shaped: 6 u32s + 1 u8 state + 39 bytes pad = 64 bytes.
    const Canonical = extern struct {
        server_seq: u32,
        sidecar_seq: u32,
        request_len: u32,
        response_len: u32,
        request_crc: u32,
        response_crc: u32,
        slot_state: u8,
        _pad: [39]u8,
    };
    comptime assert_slot_header_layout(Canonical);
}

test "assert_slot_header_layout accepts a pad-only SlotHeader" {
    // worker_dispatch shape: 6 u32s + 40 bytes pad = 64 bytes.
    const PadOnly = extern struct {
        server_seq: u32,
        sidecar_seq: u32,
        request_len: u32,
        response_len: u32,
        request_crc: u32,
        response_crc: u32,
        _pad: [40]u8,
    };
    comptime assert_slot_header_layout(PadOnly);
}
