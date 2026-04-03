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

/// Number of concurrent pipeline slots. One per sidecar connection.
/// Native handlers (no sidecar) use 1 slot (synchronous).
pub const pipeline_slots_max: u8 = if (sidecar_enabled) sidecar_count else 1;

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

// ---------------------------------------------------------------------------
// HTTP — buffer sizes.
// ---------------------------------------------------------------------------

/// Receive buffer per connection — must fit one complete HTTP request.
pub const recv_buf_max: u32 = 8 * 1024; // 8 KB

/// Send buffer per connection — must fit one complete HTTP response.
pub const send_buf_max: u32 = 256 * 1024; // 256 KB

comptime {
    assert(recv_buf_max >= 1024);
    assert(send_buf_max >= recv_buf_max);
}

// ---------------------------------------------------------------------------
// WAL — write-ahead log.
// ---------------------------------------------------------------------------

/// Maximum WAL entry size (header + recorded writes).
pub const wal_entry_max: u32 = 64 * 1024; // 64 KB

comptime {
    assert(wal_entry_max >= 1024);
}

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

/// Sidecar response deadline in ticks. If the pipeline has been pending
/// for this many ticks, terminate the sidecar connection.
pub const sidecar_response_timeout_ticks: u32 = 500; // 5 seconds at 10ms/tick

/// HTTP connection idle timeout in ticks.
pub const request_timeout_ticks: u32 = 3000; // 30 seconds at 10ms/tick

/// Log metrics emission interval in ticks.
pub const metrics_interval_ticks: u32 = 10_000; // ~100 seconds at 10ms/tick

comptime {
    assert(sidecar_response_timeout_ticks >= 1);
    assert(request_timeout_ticks > sidecar_response_timeout_ticks);
    assert(metrics_interval_ticks >= 100);
}
