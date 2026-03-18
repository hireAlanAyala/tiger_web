//! Tiger Web Framework — single-threaded HTTP server with prefetch/execute pipeline.
//!
//! Parameterized on an App type that provides domain types and functions.
//! The framework owns the tick loop, connection pool, IO, WAL, and metrics.
//! The App owns routing, business logic, and rendering.
//!
//! ## App Interface
//!
//! The App type must provide:
//!
//! **Types:**
//! - `Message` — fixed-size extern struct with `.operation`, `.set_credential()`, checksum methods
//! - `MessageResponse` — response from commit, with `.status` and `.followup: ?FollowupState`
//! - `FollowupState` — opaque struct stored on connection between SSE ticks
//! - `Operation` — enum(u8) with `.is_mutation()` method
//! - `Status` — enum(u8) with `.ok` variant
//!
//! **Type constructors:**
//! - `StateMachineType(Storage)` — returns a state machine type with `set_time`, `begin_batch`,
//!   `commit_batch`, `prefetch`, `commit` methods, and `tracer`, `secret_key`, `now` fields
//! - `Wal` — instantiated WalType for the App's Message
//!
//! **Functions:**
//! - `translate(method, path, body) -> ?Message` — HTTP routing
//! - `encode_response(buf, operation, resp, is_sse, key) -> Response` — render response
//! - `encode_followup(buf, resp, followup, key) -> Response` — render SSE followup
//! - `refresh_message() -> Message` — construct the SSE refresh message

pub const ServerType = @import("server.zig").ServerType;
pub const ConnectionType = @import("connection.zig").ConnectionType;
pub const WalType = @import("wal.zig").WalType;
pub const TracerType = @import("tracer.zig").TracerType;
pub const IO = @import("io.zig").IO;
pub const Time = @import("time.zig").Time;
pub const TimeReal = @import("time.zig").TimeReal;
pub const TimeSim = @import("time.zig").TimeSim;
pub const auth = @import("auth.zig");
pub const http = @import("http.zig");
pub const stdx = @import("stdx.zig");
pub const checksum = @import("checksum.zig");
pub const marks = @import("marks.zig");
pub const PRNG = @import("prng.zig");
pub const flags = @import("flags.zig");
pub const bench = @import("bench.zig");
