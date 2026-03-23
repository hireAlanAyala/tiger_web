# Design 011: Auth Through the Pipeline

## Problem

Cookie handling is baked into `server.zig`'s `process_inbox`. The server verifies
cookies, mints visitor IDs, reads `cookie_action` from the state machine response,
formats `Set-Cookie` headers, and passes `is_authenticated` to render. That's ~30
lines of cookie-specific logic in a file whose job is connection lifecycle.

If auth changes (bearer tokens, API keys, OAuth), `server.zig` needs rewriting.
The server should be pure plumbing: accept, recv, tick, send, close. Auth is
domain logic that belongs in the domain layer.

## Decision

Auth resolution moves into the state machine's prefetch/execute pipeline.
The server passes raw credentials on the message. The state machine resolves
identity during prefetch and produces response headers during execute. The server
never imports `auth.zig` or knows what auth strategy is in use.

Implementation is split into two steps. Step 1 moves cookie auth from the server
into the state machine pipeline — the bulk of the architectural change. Step 2
moves login code generation into the worker, validating the worker-syncs-auth-data
pattern against a concrete use case.

## Why the pipeline

### Auth is domain logic

Auth determines who the user is and what they can access. That's a domain decision.
Login, logout, session management, permission checks — these are operations the
application defines, not transport mechanics the framework provides. If the
framework user opts into auth, they own the strategy. The framework exposes the
seam; the user owns the implementation.

### Prefetch/execute already handles the hard cases

The main argument for a separate auth step was simplicity — cookie verification
is a fast HMAC check, why send it through the pipeline? But the pipeline exists
precisely for work that may need storage access:

- **Session store lookup**: verify session ID against a database table.
- **API key validation**: look up the key in a local table synced from an
  external service.
- **JWT with cached JWKS**: verify signature against locally stored public keys.
- **Revocation list checks**: confirm the token hasn't been revoked.

All of these are storage reads. Prefetch is where storage reads happen. Putting
auth in prefetch means auth that needs storage fits naturally — no special async
mechanism, no separate IO path, same back-pressure handling as every other read.

Auth strategies that don't need storage (pure HMAC cookies, stateless JWT with
embedded keys) work identically — they just don't issue a storage read during
prefetch. The pipeline handles both cases uniformly.

### Server stays single-responsibility

With auth in the pipeline, `process_inbox` becomes:

```
parse → codec → prefetch → execute → render → send
```

No auth step. No cookie logic. No `auth.zig` import. The server is a connection
lifecycle manager: accept, recv, drive the pipeline, send, timeout, close.

The ~30 lines of cookie logic in `server.zig:196-298` disappear. The cookie
fields on connection (`set_cookie_user_id`, `set_cookie_kind`) disappear.
The `secret_key` field on the server disappears — the state machine (or its
auth module) owns it.

### No auth interface on the server

An earlier design explored a comptime `Auth` parameter on `ServerType`:

```zig
ServerType(IO, Storage, Auth)
```

With `Auth` providing `resolve()` and `response_header()` methods. This works
but means the server orchestrates auth calls at two points (pre-execute and
post-execute), threading identity and state between them. The server becomes
auth-aware even though it delegates the work.

The pipeline approach eliminates the interface entirely. The server has no auth
type parameter, no auth calls, no auth state. Auth is invisible to the server —
it's just another thing the state machine does during prefetch and execute.

### Session state is request-scoped, not connection-scoped

The current cookie fields on connection (`set_cookie_user_id`, `set_cookie_kind`)
appear to be connection-scoped session state. They're not. Tracing the flow:

1. Request 1 (no cookie): server mints user_id, stores on connection, render
   emits Set-Cookie. Connection resets the fields after the response.
2. Request 2 (has cookie from response 1): server verifies cookie, extracts
   user_id. The connection fields from request 1 are gone.

Each request carries its own credentials. Resolution is per-request. The
"session state" is just request-scoped data that flows from resolve to render
within a single request, stored on the connection because that's the only
per-request storage available.

This means the state machine can handle the full lifecycle within one
prefetch/execute cycle. No connection-scoped storage needed. The state machine
sees the raw credential, resolves it, does the operation, and returns response
headers — all within one request.

No standard auth strategy requires connection-scoped state:
- Cookies: credential in every request header
- JWT/Bearer: token in every request header
- API keys: key in every request header
- OAuth: access token in every request header
- Server-side sessions: session ID in cookie, per-request lookup

---

## Step 1: Auth into the pipeline

Move cookie auth from server to state machine. The server becomes pure plumbing.
Login code generation stays in the state machine — unchanged from today.

### Message carries raw credentials

Currently the server resolves the cookie and stamps `msg.user_id` before the
state machine sees the message. Instead, the message carries the raw credential
and the state machine resolves it:

```
Before:  server verifies cookie → msg.user_id = resolved_id
After:   msg.credential = raw_cookie_bytes → state machine resolves in prefetch
```

The `Message` already has a `reserved: [15]u8` field in the header. The raw
credential doesn't go here — it's too large (cookies are 97 bytes, JWTs can be
hundreds). Instead, the credential goes in the body alongside the operation's
event data, or the message gets a dedicated credential field.

The practical approach: add a `credential` field to the message header. Cookie
values are fixed at 97 bytes. A `credential: [credential_max]u8` field with
`credential_len: u8` accommodates cookies and most bearer tokens. The Message
is already 784 bytes; this adds a fixed cost per message but avoids mixing
credentials with operation event data in the body.

Alternatively, the credential stays in the parsed HTTP headers and the state
machine receives a reference to the raw header bytes. This avoids enlarging
Message but means the state machine needs access to connection-owned memory
during prefetch — a tighter coupling than copying into the message.

### Prefetch resolves identity

The state machine's prefetch phase gains an auth resolution step:

```zig
fn prefetch(self: *StateMachine, msg: Message) bool {
    // Auth resolution — before operation-specific prefetch.
    self.prefetch_identity = self.resolve_credential(msg.credential());
    if (self.prefetch_identity == null) {
        // No valid credential — still proceed. Anonymous visitor.
        self.prefetch_identity = self.mint_anonymous(msg);
    }

    // Operation-specific prefetch (storage reads).
    switch (msg.operation) {
        .list_products => ...
        .create_product => ...
    }
}
```

For cookie auth, `resolve_credential` is an HMAC verify — pure computation,
no storage needed. For session-store auth, it's a storage read — same as
prefetching a product. If storage is busy, prefetch returns false and the
request retries next tick, same as any other back-pressure.

### Execute uses resolved identity

Execute reads the identity from the prefetch cache:

```zig
fn commit(self: *StateMachine, msg: Message) MessageResponse {
    const identity = self.prefetch_identity.?;
    // identity.user_id, identity.is_authenticated available for business logic
    ...
}
```

Operations that need auth gating (protected routes) check
`identity.is_authenticated`. The state machine owns this decision, not the
server, not render.

### Response carries session action, state machine translates to headers

Execute handlers return a semantic `session_action` signal — the same pattern
as today's `cookie_action`, renamed:

```zig
// state_machine.zig — execute handlers stay clean
.logout => .{ .status = .ok, .result = .{ .empty = {} }, .session_action = .clear },

.verify_login_code => .{
    .status = .ok,
    .result = .{ .login = login_result },
    .session_action = .set_authenticated,
},

.list_products => .{
    .status = .ok,
    .result = .{ .product_list = list },
    // session_action defaults to .none
},
```

The state machine's `commit()` wrapper translates the semantic action into
opaque response header bytes before returning to the server:

```zig
pub fn commit(self: *StateMachine, msg: Message) MessageResponse {
    var resp = self.execute(msg);
    self.apply_auth_response(&resp);
    defer self.reset_prefetch();
    defer self.invariants();
    return resp;
}

fn apply_auth_response(self: *StateMachine, resp: *MessageResponse) void {
    const identity = self.prefetch_identity.?;
    resp.is_authenticated = identity.is_authenticated;

    switch (resp.session_action) {
        .none => {
            // New visitor (no valid credential) — set anonymous cookie.
            if (identity.is_new) {
                resp.response_header_len = auth.format_set_cookie_header(
                    &resp.response_header, identity.user_id,
                    .anonymous, self.secret_key,
                ).len;
            }
        },
        .set_authenticated => {
            const login_result = resp.result.login;
            resp.response_header_len = auth.format_set_cookie_header(
                &resp.response_header, login_result.user_id,
                .authenticated, self.secret_key,
            ).len;
        },
        .clear => {
            resp.response_header_len = auth.format_clear_cookie_header(
                &resp.response_header, identity.user_id,
                identity.kind, self.secret_key,
            ).len;
        },
    }
}
```

This keeps both properties:
- **Execute handlers stay semantic.** They return `.session_action = .clear`,
  not HTTP header bytes. No formatting logic in business operations.
- **The server stays ignorant.** It sees `response_header` bytes and
  `is_authenticated`. It never interprets `session_action` — that translation
  happens inside the state machine before the response crosses the boundary.

The `session_action` field exists on `MessageResponse` as an internal signal
between execute and `apply_auth_response`. The server never reads it. If the
field is private to the state machine (not on `MessageResponse` but on an
internal struct), even better — but the current pattern of execute returning
`MessageResponse` directly means it lives there. The server ignores it.

Swapping auth strategies means replacing `apply_auth_response`. Cookie auth
formats `Set-Cookie`. Bearer auth formats nothing (or `WWW-Authenticate` on
deny). API key auth formats nothing. The execute handlers don't change — they
still return `.session_action = .set_authenticated` on login. The translation
layer decides what that means over the wire.

### Render receives is_authenticated

Render currently gates protected routes:

```zig
// render.zig:324
if (!is_authenticated and !is_login_route) {
    encode_login_page_body(&w, null);
}
```

This doesn't change structurally. `is_authenticated` comes from the
`MessageResponse` instead of from the server's cookie verification. Render
still doesn't know the auth strategy — it sees a bool and decides whether
to show content or the login page.

For non-HTML auth strategies (bearer tokens, API keys) where a login page
makes no sense, the state machine would return a different response entirely
(e.g., an error status) for unauthenticated requests, and render would
handle that through the normal error path. The auth strategy controls what
"unauthenticated" looks like by controlling what the state machine returns.

### Server becomes pure plumbing

After extraction, `process_inbox` in `server.zig` becomes:

```zig
fn process_inbox(server: *Server) void {
    server.state_machine.set_time(server.time.realtime());
    server.state_machine.begin_batch();
    defer server.state_machine.commit_batch();

    for (server.connections) |*conn| {
        if (conn.state != .ready) continue;
        if (conn.pending_followup) continue;

        const parsed = switch (http.parse_request(conn.recv_buf[0..conn.recv_pos])) {
            .complete => |p| p,
            .incomplete, .invalid => unreachable,
        };

        var msg = codec.translate(parsed.method, parsed.path, parsed.body) orelse {
            log.mark.warn("unmapped request fd={d}", .{conn.fd});
            conn.state = .closing;
            continue;
        };
        msg.set_credential(parsed);  // copy raw credential bytes onto message
        conn.is_datastar_request = parsed.is_datastar_request;

        // Prefetch (includes auth resolution).
        server.state_machine.tracer.start(.prefetch);
        if (!server.state_machine.prefetch(msg)) {
            server.state_machine.tracer.cancel(.prefetch);
            continue;
        }
        server.state_machine.tracer.stop(.prefetch, msg.operation);

        // Execute (uses resolved identity, produces response headers).
        server.state_machine.tracer.start(.execute);
        const resp = server.state_machine.commit(msg);
        server.state_machine.tracer.stop(.execute, msg.operation);
        server.state_machine.tracer.trace_log(msg.operation, resp.status, conn.fd);

        // WAL.
        if (server.wal) |wal| {
            if (!wal.disabled and msg.operation.is_mutation()) {
                const timestamp = server.state_machine.now;
                const entry = wal.prepare(msg, timestamp);
                wal.append(&entry);
            }
        }

        // SSE follow-up check.
        // ... same as today, minus cookie_action check ...

        // Render. response_header is opaque bytes from the state machine.
        const r = render.encode_response(
            &conn.send_buf, msg.operation, resp,
            conn.is_datastar_request,
            resp.response_header_slice(),
            resp.is_authenticated,
        );
        conn.set_response(r.offset, r.len);
        conn.keep_alive = r.keep_alive;
    }
}
```

Removed from server: `auth` import, `secret_key` field, `prng` for minting,
cookie verification, cookie_action dispatch, `Set-Cookie` header formatting,
`is_authenticated` derivation. The connection loses `set_cookie_user_id` and
`set_cookie_kind`.

### process_followups simplifies

The follow-up path currently duplicates cookie header formatting
(`server.zig:351-355`). With auth in the pipeline, the state machine produces
response headers for follow-ups the same way it does for regular requests.
No special cookie handling in follow-ups.

### Step 1 — what changes

| File | Change |
|---|---|
| `server.zig` | Remove `auth` import, `secret_key` field, cookie logic from `process_inbox` and `process_followups`. Add `msg.set_credential(parsed)`. |
| `connection.zig` | Remove `set_cookie_user_id`, `set_cookie_kind` fields. |
| `message.zig` | Add credential field to `Message`. Add `response_header`, `response_header_len`, `is_authenticated` to `MessageResponse`. Rename `CookieAction` to `SessionAction` (internal to state machine). |
| `state_machine.zig` | Add `prefetch_identity` cache field. Add `resolve_credential()` in prefetch. Add `apply_auth_response()` post-execute step to translate `session_action` into response header bytes. Move `secret_key` here from server. |
| `render.zig` | Receive `response_header: ?[]const u8` and `is_authenticated: bool` from `MessageResponse` instead of from the server. Signature change, not logic change. |
| `http.zig` | Extract raw credential bytes generically (full `Cookie` header value or `Authorization` header value) instead of specifically parsing `tiger_id`. |
| `codec.zig` | No change. Codec translates routes — it never touches auth. |
| `auth.zig` | Unchanged internally. Imported by `state_machine.zig` instead of `server.zig`. |
| `auditor.zig` | Update assertions: check `response_header` bytes and `is_authenticated` instead of `cookie_action`. |
| `sim.zig` | Update sim client to check `Set-Cookie` in response headers produced by the state machine instead of by the server. |
| `fuzz.zig` | State machine fuzzer supplies raw credentials on messages instead of pre-resolved `user_id`. |
| `render_fuzz.zig` | Update to pass `response_header` bytes instead of `set_cookie_header`. |

---

## Step 2: Login code generation via worker

Move login code generation from the state machine into the worker. This
validates the worker-syncs-auth-data pattern from the "Remote auth via worker"
section against a concrete use case. The email code login simulates a third-party
auth provider: the worker is the "external service" that generates and delivers
codes.

### Why this is a good exercise

The current login flow is synchronous:

```
POST /login/code → execute generates code → stores it → server logs it → done
```

A real email provider (SendGrid, Postmark) is asynchronous: you call their API,
they queue the email, it arrives seconds later. Moving code generation to the
worker makes the flow async in the same way:

```
POST /login/code → execute stores pending request → 200 "code sent"
Worker polls    → sees pending request → generates code → stores it → (simulates email)
POST /login/verify → execute verifies code → authenticated
```

The user already expects to wait for an email. The worker's poll interval
(1-2 seconds) simulates realistic delivery latency. This is honest simulation,
not artificial delay.

### How it works

#### State machine changes

`execute_request_login_code` no longer generates a code. It stores a pending
code request:

```zig
fn execute_request_login_code(self: *StateMachine, event: LoginCodeRequest, result: StorageResult) MessageResponse {
    // Store pending request — worker will generate the code.
    const wr = self.storage.put_pending_login(event.email[0..event.email_len], self.now);
    return switch (wr) {
        .ok => MessageResponse.empty_ok,  // "code sent" (pending)
        .busy, .err => MessageResponse.storage_error,
        else => unreachable,
    };
}
```

`execute_verify_login_code` is unchanged — it still verifies a code from the
login_codes table. The code just got there via the worker instead of via execute.

#### Storage changes

New table/operation: `pending_logins` — stores email + requested_at timestamp.
The worker queries for pending entries, the state machine writes them.

The existing `login_codes` table is unchanged. The worker writes to it instead
of the state machine.

#### Worker changes

The worker gains a new poll task: check for pending login requests, generate
codes, store them, log them (simulating email delivery).

```
Worker poll cycle:
  1. GET /internal/pending-logins → list of (email, requested_at)
  2. For each pending entry:
     a. Generate 6-digit code
     b. POST /internal/login-codes { email, code, expires_at }
     c. Log: "login code for alice@example.com: 123456"
  3. Server deletes pending entries after worker confirms
```

The `/internal/*` endpoints are worker-only — not exposed to external clients.
The codec can reject them from external connections, or they can use a separate
auth mechanism (shared secret, localhost-only).

Alternatively, the worker writes directly to storage (SQLite) without going
through the HTTP pipeline. This is simpler — the worker already has a database
connection in production. The pending_logins and login_codes tables are just
SQLite tables the worker reads and writes.

#### Latency consideration

The worker polls on a schedule. At a 1-second interval, the user waits up to
1 second for their code. At 10 seconds, the wait is noticeable. For the login
code use case, the worker should poll for pending logins on a tight interval
(1-2 seconds) or use a signal mechanism where the server notifies the worker
that work is waiting.

This mirrors real email delivery latency: SendGrid typically delivers within
1-5 seconds. The simulation is honest.

### Step 2 — what changes

| File | Change |
|---|---|
| `state_machine.zig` | `execute_request_login_code` stores pending request instead of generating code. Remove `generate_login_code`. |
| `storage.zig` | Add `pending_logins` table. Add `put_pending_login`, `get_pending_logins`, `delete_pending_login`. |
| `worker.zig` | Add pending login poll task. Generate codes, store in `login_codes` table, log to console. |
| `server.zig` | Remove login code console logging (moves to worker). |

### Step 2 is independently reversible

Step 2 changes only the login code flow. If the worker pattern proves awkward
(latency too high, complexity not worth it), revert step 2 and keep step 1.
The auth pipeline stands on its own — the worker pattern is an experiment on top.

---

## Remote auth via worker (general pattern)

Step 2 validates one instance of a general pattern. Auth strategies that require
remote validation (OAuth token introspection, external API key services, SAML
IdPs) can't resolve inside the single-threaded pipeline — there's no outbound
HTTP client.

The worker handles remote IO on its own schedule, keeps local storage current.
The state machine resolves per-request from local data. The pipeline stays
synchronous and single-threaded.

- **JWT JWKS**: worker fetches the provider's public key endpoint periodically,
  writes keys to storage. State machine verifies JWT signatures using locally
  cached keys during prefetch.
- **API key sync**: worker polls an admin API for the current key set, writes
  to a local table. State machine looks up keys from local storage.
- **Revocation lists**: worker fetches revoked token lists from the provider,
  stores locally. State machine checks the list during verification.
- **User/permission sync**: worker syncs allowed users or role assignments
  from an external directory into local storage.

Per-request remote introspection (every token individually validated with the
provider) doesn't fit this pattern. That's the edge proxy case — a reverse
proxy in front validates tokens and forwards resolved identity as a trusted
header (`X-User-Id`). The state machine reads the header from the credential
field. The pipeline works; the remote IO happens outside the server process.
