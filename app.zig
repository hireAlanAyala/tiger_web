//! App — the domain binding consumed by the framework.
//!
//! Provides types, functions, and constants that the framework's ServerType
//! calls at comptime. The framework never switches on Operation — it reads
//! response fields and calls these functions.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const codec = @import("codec.zig");
const render = @import("render.zig");
const http = @import("tiger_framework").http;
const auth = @import("tiger_framework").auth;
const marks = @import("tiger_framework").marks;
pub const SidecarClient = @import("sidecar.zig").SidecarClient;

const log = marks.wrap_log(std.log.scoped(.app));

pub const Message = message.Message;
pub const MessageResponse = message.MessageResponse;
pub const FollowupState = message.FollowupState;
pub const Operation = message.Operation;
pub const Status = message.Status;
pub const StateMachineType = @import("state_machine.zig").StateMachineType;
pub const Wal = @import("tiger_framework").wal.WalType(Message, message.wal_root);

/// Optional sidecar client — when set, translate delegates to the
/// external process instead of the Zig-native codec.
pub var sidecar: ?SidecarClient = null;

/// Translate an HTTP request into a typed Message. Returns null if the
/// request doesn't map to a valid operation.
///
/// When the sidecar is active, runs BOTH paths and compares results
/// (spot-check). The sidecar result is used; divergence is logged as
/// an error. The Zig-native translate is pure (~1μs) so the overhead
/// of running both is negligible compared to the socket round trip.
pub fn translate(method: http.Method, path: []const u8, body: []const u8) ?Message {
    if (sidecar) |*client| {
        const sidecar_result = client.translate(method, path, body);
        const native_result = codec.translate(method, path, body);
        spot_check_translate(path, sidecar_result, native_result);
        return sidecar_result;
    }
    return codec.translate(method, path, body);
}

/// Compare sidecar and Zig-native translate results. Log divergence.
/// Does NOT panic — the sidecar result is used regardless. Divergence
/// means the developer's handler has a bug, not that the system is corrupt.
fn spot_check_translate(path: []const u8, sidecar_result: ?Message, native_result: ?Message) void {
    const sidecar_msg = sidecar_result orelse {
        if (native_result != null) {
            log.mark.err("spot-check divergence: sidecar=null native={s} path={s}", .{
                @tagName(native_result.?.operation), path,
            });
        }
        return;
    };
    const native_msg = native_result orelse {
        log.mark.err("spot-check divergence: sidecar={s} native=null path={s}", .{
            @tagName(sidecar_msg.operation), path,
        });
        return;
    };

    // Compare operation.
    if (sidecar_msg.operation != native_msg.operation) {
        log.mark.err("spot-check divergence: operation sidecar={s} native={s} path={s}", .{
            @tagName(sidecar_msg.operation), @tagName(native_msg.operation), path,
        });
        return;
    }

    // Compare entity ID.
    if (sidecar_msg.id != native_msg.id) {
        log.mark.err("spot-check divergence: id mismatch for {s} path={s}", .{
            @tagName(sidecar_msg.operation), path,
        });
        return;
    }

    // Compare body bytes.
    if (!std.mem.eql(u8, &sidecar_msg.body, &native_msg.body)) {
        log.mark.err("spot-check divergence: body mismatch for {s} path={s}", .{
            @tagName(sidecar_msg.operation), path,
        });
    }
}

/// Encode a response into the send buffer.
pub fn encode_response(send_buf: []u8, operation: Operation, resp: MessageResponse, is_datastar_request: bool, secret_key: *const [auth.key_length]u8) render.Response {
    return render.encode_response(send_buf, operation, resp, is_datastar_request, secret_key);
}

/// Encode an SSE followup (dashboard refresh after mutation) into the send buffer.
pub fn encode_followup(send_buf: []u8, resp: MessageResponse, followup: *const FollowupState, secret_key: *const [auth.key_length]u8) render.Response {
    return render.encode_followup(send_buf, &resp.result.page_load_dashboard, followup, secret_key);
}

/// Construct the message used for SSE follow-up refreshes.
pub fn refresh_message() Message {
    return Message.init(.page_load_dashboard, 0, 0, {});
}
