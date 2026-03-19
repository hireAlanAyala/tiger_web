//! Sidecar wire protocol — fixed-size binary messages between the Zig
//! framework and the TypeScript sidecar over a unix socket.
//!
//! Two round trips per HTTP request:
//!   1. Translate: method + path + body → operation + id + typed event
//!   2. Execute + Render: operation + cache → status + writes + HTML
//!
//! This file defines round trip 1 (translate). Round trip 2 is pending
//! cache serialization design (see design/013, Step 3b).

const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("tiger_framework").stdx;
const message = @import("message.zig");

/// Maximum URL path length in the translate request.
pub const path_max = 256;

/// Maximum raw HTTP body (JSON text) in the translate request.
pub const json_body_max = 4096;

/// Protocol message tag — identifies the round trip type.
pub const Tag = enum(u8) {
    translate = 0x01,
    execute_render = 0x02,
};

/// HTTP method — subset relevant to the application.
pub const Method = enum(u8) {
    get = 1,
    post = 2,
    put = 3,
    delete = 4,
};

/// Translate request: Zig → sidecar.
/// Carries the raw HTTP request for the sidecar to route and parse.
/// Fields ordered to avoid padding: small fields first, then arrays.
pub const TranslateRequest = extern struct {
    tag: Tag,
    method: Method,
    path_len: u16,
    body_len: u16,
    reserved: [2]u8,
    path: [path_max]u8,
    body: [json_body_max]u8,

    comptime {
        assert(stdx.no_padding(TranslateRequest));
        // tag(1) + method(1) + path_len(2) + body_len(2) + reserved(2)
        // + path(256) + body(4096) = 4360
        assert(@sizeOf(TranslateRequest) == 4360);
        assert(path_max > 0);
        assert(path_max <= std.math.maxInt(u16));
        assert(json_body_max > 0);
        assert(json_body_max <= std.math.maxInt(u16));
    }

    pub fn path_slice(self: *const TranslateRequest) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn body_slice(self: *const TranslateRequest) []const u8 {
        return self.body[0..self.body_len];
    }
};

/// Translate response: sidecar → Zig.
/// Carries the routed operation and typed event body.
/// Fields ordered largest-alignment first to avoid padding.
pub const TranslateResponse = extern struct {
    id: u128,
    body: [message.body_max]u8,
    found: u8,
    operation: message.Operation,
    reserved: [14]u8,

    comptime {
        assert(stdx.no_padding(TranslateResponse));
        // id(16) + body(672) + found(1) + operation(1) + reserved(14) = 704
        assert(@sizeOf(TranslateResponse) == 704);
        // Size must be aligned to u128 alignment (16 bytes).
        assert(@sizeOf(TranslateResponse) % @alignOf(u128) == 0);
    }
};
