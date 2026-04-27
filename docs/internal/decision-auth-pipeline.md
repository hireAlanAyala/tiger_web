# Auth Through the Pipeline

## Decision

Auth resolution moved from server.zig into the state machine's
prefetch/execute pipeline. The server passes raw credentials on the
message. The state machine resolves identity during prefetch and
produces session actions during execute. The server never imports
auth.zig or knows what auth strategy is in use.

## Why

**Auth is domain logic.** Login, logout, session management, permission
checks are operations the application defines, not transport mechanics.
The framework exposes the seam; the user owns the strategy.

**Prefetch/execute handles the hard cases.** Cookie verification is a
fast HMAC check. But remote auth (JWT JWKS refresh, API key validation,
OAuth token introspection) requires storage reads and possibly network
calls. The pipeline already handles storage reads with back-pressure
(returns null = retry next tick). Auth benefits from the same mechanism.

**Single responsibility.** Server.zig becomes pure plumbing: accept,
recv, tick, send, close. No cookie parsing, no session logic, no
secret_key field.

## Implementation

`resolve_credential()` in state_machine.zig prefetch phase:
- Reads raw credential bytes from message
- Verifies cookie HMAC via auth.zig
- Stores resolved identity on `prefetch_identity` field
- If no credential or invalid: mints anonymous visitor ID

`apply_auth_response()` post-execute:
- Translates `session_action` (.set_authenticated, .clear, .none)
  into cookie header bytes on the response

## Alternatives explored

**Separate auth middleware step before pipeline.** Rejected — creates
a special case. Auth would be the only thing that runs outside the
prefetch/execute model. The pipeline already does what auth needs.

**Auth in server.zig (original).** Worked for cookies. Breaks for any
auth strategy requiring storage reads. The server shouldn't know what
auth strategy is in use.
