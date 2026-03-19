//! App — the domain binding consumed by the framework.
//!
//! Provides types, functions, and constants that the framework's ServerType
//! calls at comptime. The framework never switches on Operation — it reads
//! response fields and calls these functions.

const message = @import("message.zig");
const codec = @import("codec.zig");
const render = @import("render.zig");
const http = @import("tiger_framework").http;
const auth = @import("tiger_framework").auth;
pub const SidecarClient = @import("sidecar.zig").SidecarClient;

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
pub fn translate(method: http.Method, path: []const u8, body: []const u8) ?Message {
    if (sidecar) |*client| return client.translate(method, path, body);
    return codec.translate(method, path, body);
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
