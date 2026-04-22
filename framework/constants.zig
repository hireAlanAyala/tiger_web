//! Constants — the single source of truth for architectural limits.
//!
//! Every cross-module constant lives here. Modules import from constants,
//! never derive independently. Follows TigerBeetle's constants.zig exactly:
//!   - Config flattening: build options → public constants
//!   - Derivation: new constants from combinations of other constants
//!   - Validation: comptime blocks assert invariant relationships
//!
//! If a constant is used by more than one module, it belongs here.
//! If a constant is derived from another constant, both belong here.
//! If two constants must maintain a relationship, assert it here.

const std = @import("std");
const assert = std.debug.assert;

// ---------------------------------------------------------------------------
// Build options — flattened from build_options (set per compilation target).
// Native: sidecar_enabled=false, sidecar_count=1.
// Sidecar: sidecar_enabled=true, sidecar_count=N.
// ---------------------------------------------------------------------------

const build_options = @import("build_options");

/// Extra runtime checks (TB pattern). Enabled in Debug/ReleaseSafe.
pub const verify = std.debug.runtime_safety;

pub const sidecar_enabled: bool = build_options.sidecar_enabled;
pub const sidecar_count: u8 = build_options.sidecar_count;

comptime {
    assert(sidecar_count >= 1);
    assert(sidecar_count <= 32); // bounded — pipeline_slots_max derives from this
    if (!sidecar_enabled) assert(sidecar_count == 1);
}

// ---------------------------------------------------------------------------
// Pipeline — concurrent dispatch slots.
// ---------------------------------------------------------------------------

/// Number of concurrent pipeline slots. Decoupled from sidecar_count
/// to allow N slots sharing M connections (N >= M). With async
/// multiplexing, one TS process handles many concurrent requests.
/// Native handlers (no sidecar) use 1 slot (synchronous).
pub const pipeline_slots_max: u8 = if (sidecar_enabled) build_options.pipeline_slots else 1;

comptime {
    assert(pipeline_slots_max >= 1);
    assert(pipeline_slots_max <= 32); // bounded — trace arrays sized to this
}

// ---------------------------------------------------------------------------
// Server — connection pool.
// ---------------------------------------------------------------------------

/// Maximum HTTP connections the server can handle simultaneously.
pub const max_connections: u32 = 128;

comptime {
    assert(max_connections >= 1);
    assert(max_connections <= std.math.maxInt(u32));
    // Must have more connections than pipeline slots — each slot serves
    // one connection, but many connections can be receiving/sending.
    assert(max_connections >= pipeline_slots_max);
}

// ---------------------------------------------------------------------------
// Protocol — binary frame limits.
// ---------------------------------------------------------------------------

/// Maximum payload size for a single CALL/RESULT/QUERY frame.
pub const frame_max: u32 = 256 * 1024; // 256 KB

/// Maximum QUERY round-trips per CALL. Bounds the QUERY sub-protocol
/// to prevent a rogue sidecar from sending unbounded queries.
pub const queries_max: u32 = 64;

comptime {
    assert(frame_max >= 1024); // reasonable minimum
    assert(frame_max <= 1024 * 1024); // 1 MB max
    assert(queries_max >= 1);
}

// HTTP buffer sizes live in framework/http.zig — the single source of truth
// for recv_buf_max, send_buf_max, max_header_size, body_max. Not duplicated
// here because http.zig is imported by everything that needs buffer sizes.


// ---------------------------------------------------------------------------
// Auth — cookie signing.
// ---------------------------------------------------------------------------

/// HMAC-SHA256 key length for cookie signing.
pub const auth_key_length: u32 = 32;

// ---------------------------------------------------------------------------
// Timing — tick intervals.
// ---------------------------------------------------------------------------

/// Server tick interval in milliseconds (for documentation — the actual
/// interval is controlled by IO.run_for_ns at the call site).
pub const tick_ms: u32 = 10;

/// Disk sector size for Direct I/O alignment (TB pattern).
pub const sector_size: u32 = 4096;

/// CPU cache-line size in bytes. Used for aligned allocations where
/// false-sharing must be avoided and for benchmark buffers aligned to
/// a realistic load boundary. Matches TB's
/// `src/constants.zig:cache_line_size` (= `config.cluster.cache_line_size`
/// = 64 on x86_64 and arm64 — TB's `src/config.zig:154`).
pub const cache_line_size: u16 = 64;

comptime {
    // Bounds check against ISA reality — every mainstream cache-line is
    // between 16 (original ARM) and 256 (some POWER variants). A value
    // outside this range is a typo, not a port to a real architecture.
    assert(cache_line_size >= 16);
    assert(cache_line_size <= 256);
    // Power-of-two — required by alignedAlloc, and true of every
    // real-world cache-line size.
    assert(std.math.isPowerOfTwo(cache_line_size));
    // Cache-line must be large enough to hold an atomic u64 without
    // straddling two lines — the use-case that motivates aligning to
    // it in the first place.
    assert(cache_line_size >= @alignOf(std.atomic.Value(u64)));
}

/// Sidecar response deadline in ticks. If the pipeline has been pending
/// for this many ticks, terminate the sidecar connection.
pub const sidecar_response_timeout_ticks: u32 = 500; // 5 seconds at 10ms/tick

// HTTP connection idle timeout: handled by kernel TCP_USER_TIMEOUT
// (set in io.zig set_tcp_options: 90s). No application-level scanning.
// TB pattern: kernel handles idle detection, not the tick loop.

/// Log metrics emission interval in ticks.
pub const metrics_interval_ticks: u32 = 10_000; // ~100 seconds at 10ms/tick

comptime {
    assert(sidecar_response_timeout_ticks >= 1);
    assert(metrics_interval_ticks >= 100);
}

// ---------------------------------------------------------------------------
// Workers — background dispatch.
// ---------------------------------------------------------------------------

/// Maximum concurrent in-flight worker dispatches.
pub const max_in_flight_workers: u8 = 16;

/// Maximum worker name length (ASCII, validated by scanner).
pub const worker_name_max: u8 = 64;

/// Maximum serialized args size per dispatch.
pub const worker_args_max: u16 = 4096;

/// Maximum worker result data size.
pub const worker_result_max: u16 = 4096;

/// Maximum worker dispatches per handler invocation.
pub const dispatches_per_handle_max: u8 = 4;

/// Worker deadline in ticks. If a dispatch has been pending for this
/// many ticks, it is resolved dead.
pub const worker_deadline_ticks: u32 = 3000; // 30 seconds at 10ms/tick

comptime {
    assert(max_in_flight_workers >= 1);
    assert(max_in_flight_workers <= 64); // bounded — static allocation
    assert(worker_name_max >= 1);
    assert(worker_name_max <= 128);
    assert(worker_args_max >= 1);
    assert(worker_args_max <= 8192);
    assert(worker_deadline_ticks >= 100); // at least 1 second
}
