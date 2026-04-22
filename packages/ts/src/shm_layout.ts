// Shared memory layout primitives — the TS mirror of framework/shm_layout.zig.
//
// One source of truth, referenced by name. Every CALL/RESULT write and
// every CRC check routes through `crcFrame` and `HEADER_OFFSETS` here
// so the Zig↔C↔TS wire contract can only drift in one place.
//
// Pair assertion: `selfTest` runs on module load and recomputes the
// canonical cross-language test vector. If it diverges from the Zig
// or C implementation the process aborts — matches the CRC self-test
// in shm.c (init-time) and worker_dispatch.zig ("CRC32 cross-language
// test vector" test).

import { crc32 } from "node:zlib";

/// Length-prefix CRC convention: CRC32(LE u32 len ++ payload[0..len]).
///
/// A corrupted length produces a CRC mismatch rather than a garbage
/// read. Matches Zig's `framework/shm_layout.zig:crc_frame` and C's
/// `packages/ts/native/shm.c:compute_crc`.
export function crcFrame(len: number, payload: Uint8Array): number {
  if ((len >>> 0) !== len) {
    throw new Error(`crcFrame: len must be a u32, got ${len}`);
  }
  if (payload.length < len) {
    throw new Error(`crcFrame: payload.length=${payload.length} < len=${len}`);
  }
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32LE(len, 0);
  return crc32(Buffer.concat([lenBuf, payload.subarray(0, len)])) >>> 0;
}

/// Canonical field offsets inside a slot header. Mirrors the contract
/// in `packages/vectors/shm_layout.json` and the pair-assertion in
/// `framework/shm_layout.zig:assert_slot_header_layout`.
export const HEADER_OFFSETS = Object.freeze({
  SERVER_SEQ: 0,
  SIDECAR_SEQ: 4,
  REQUEST_LEN: 8,
  RESPONSE_LEN: 12,
  REQUEST_CRC: 16,
  RESPONSE_CRC: 20,
  SLOT_STATE: 24, // shm_bus only; worker_dispatch reserves this byte.
  SLOT_HEADER_SIZE: 64,
});

/// Region header offsets. 64 bytes of capacity metadata at offset 0
/// of every SHM region.
export const REGION_OFFSETS = Object.freeze({
  SLOT_COUNT: 0,      // u16 LE
  FRAME_MAX: 4,       // u32 LE
  REGION_HEADER_SIZE: 64,
});

/// Canonical cross-language CRC test vector: payload "hello" (5 bytes),
/// framed as [0x05, 0x00, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f].
/// Expected CRC32 = 0x5CAC007A.
///
/// Identical vector is asserted in:
///   - framework/worker_dispatch.zig : test "CRC32 cross-language test vector"
///   - packages/ts/native/shm.c      : verify_crc_table (init-time)
///
/// If any language's implementation drifts, this three-way check fails.
export const CROSS_LANGUAGE_VECTOR = Object.freeze({
  payload: "hello",
  expectedCrc: 0x5CAC007A,
});

/// Startup pair-assertion. Run once at module load; throws (not silent
/// return) if the CRC doesn't match, since a silent mismatch would
/// drop every SHM frame with no visible error.
function selfTest(): void {
  const payload = new TextEncoder().encode(CROSS_LANGUAGE_VECTOR.payload);
  const actual = crcFrame(payload.length, payload);
  if (actual !== CROSS_LANGUAGE_VECTOR.expectedCrc) {
    throw new Error(
      `shm_layout: CRC self-test failed. Got 0x${actual.toString(16).toUpperCase()}, ` +
      `expected 0x${CROSS_LANGUAGE_VECTOR.expectedCrc.toString(16).toUpperCase()}. ` +
      `node:zlib crc32 has diverged from the Zig/C contract — all SHM frames would fail.`,
    );
  }
}

selfTest();
