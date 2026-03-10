//! Shared utilities for fuzz tests.

pub const FuzzArgs = struct {
    seed: u64,
    events_max: ?usize,
};
