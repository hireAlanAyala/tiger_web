# Auth Pipeline — Step 2: Login Code via Worker

> Step 1 (auth into the pipeline) is complete. See decisions/auth-pipeline.md.
> This plan covers step 2: login code generation via worker.

## Problem

The current login flow is synchronous — execute generates a code and
the server logs it. A real email provider (SendGrid, Postmark) is
async. Moving code generation to the worker makes the flow honest:

```
POST /login/code → execute stores pending request → 200 "code sent"
Worker polls    → sees pending → generates code → stores it → (simulates email)
POST /login/verify → execute verifies code → authenticated
```

## How it works

### State machine

`execute_request_login_code` stores a pending request instead of
generating a code:

```zig
fn execute_request_login_code(...) MessageResponse {
    const wr = self.storage.put_pending_login(event.email[0..event.email_len], self.now);
    return switch (wr) {
        .ok => MessageResponse.empty_ok,
        .busy, .err => MessageResponse.storage_error,
        else => unreachable,
    };
}
```

`execute_verify_login_code` is unchanged — it verifies a code from
login_codes. The code just got there via the worker.

### Storage

New table: `pending_logins` (email, requested_at). Worker reads them,
state machine writes them. Existing `login_codes` table unchanged —
worker writes to it instead of the state machine.

### Worker

New poll task: check pending_logins, generate codes, store in
login_codes, log to console (simulating email delivery).

The worker can write directly to SQLite (it has a connection) or
go through internal HTTP endpoints. Direct is simpler.

### Latency

Worker polls on 1-2 second intervals. Mirrors real email delivery
(SendGrid typically delivers within 1-5 seconds). The simulation
is honest, not artificially delayed.

## What changes

| File | Change |
|---|---|
| `state_machine.zig` | `execute_request_login_code` stores pending request, remove `generate_login_code` |
| `storage.zig` | Add `pending_logins` table, put/get/delete operations |
| `worker.zig` | Add pending login poll task, generate codes, store, log |
| `server.zig` | Remove login code console logging (moves to worker) |

## Independently reversible

Step 2 changes only the login code flow. If the worker pattern proves
awkward, revert step 2 and keep step 1. The auth pipeline stands on
its own.

## Remote auth via worker (general pattern)

Step 2 validates one instance of a general pattern. Auth strategies
requiring remote validation can't resolve inside the single-threaded
pipeline — there's no outbound HTTP client.

The worker handles remote IO on its own schedule, keeps local storage
current. The state machine resolves per-request from local data.

- **JWT JWKS**: worker fetches public keys periodically, state machine
  verifies locally
- **API key sync**: worker polls admin API, state machine looks up locally
- **Revocation lists**: worker fetches, state machine checks locally
- **User/permission sync**: worker syncs from external directory

Per-request remote introspection (every token validated with provider)
doesn't fit this pattern — that's an edge proxy case. The proxy
validates and forwards resolved identity as a trusted header.
