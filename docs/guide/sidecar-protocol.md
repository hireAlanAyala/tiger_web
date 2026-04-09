# Sidecar Protocol Specification

The sidecar communicates with the server over shared memory (SHM).
This document is the complete adapter contract — everything a new
language implementation needs.

## Startup

The server creates two SHM regions:

| Region | Name | Purpose |
|--------|------|---------|
| Request | `tiger-{pid}` | HTTP request dispatch (1-RT and 2-RT) |
| Worker | `tiger-{pid}-workers` | Async worker dispatch + QUERY sub-protocol |

The sidecar receives the request SHM name as CLI arg 1. The worker
SHM name is `{request_name}-workers`. Both regions are POSIX shared
memory (`/dev/shm/`).

## SHM Region Layout

```
RegionHeader (64 bytes)
  epoch:      u32 LE @ 0    — global counter, bumped after every server write.
                               Sidecar futex-waits on this address.
  slot_count: u16 LE @ 4    — number of slot pairs in this region.
  frame_max:  u32 LE @ 8    — maximum frame payload size (bytes).
  _pad:       54 bytes       — zero padding to 64 bytes.

SlotPair[slot_count] — one per concurrent dispatch slot:
  SlotHeader (64 bytes)
    server_seq:   u32 LE @ 0   — server bumps after writing a request.
    sidecar_seq:  u32 LE @ 4   — sidecar bumps after writing a response.
    request_len:  u32 LE @ 8   — payload length in request area.
    response_len: u32 LE @ 12  — payload length in response area.
    request_crc:  u32 LE @ 16  — CRC32 of (le_u32(request_len) ++ request[0..request_len]).
    response_crc: u32 LE @ 20  — CRC32 of (le_u32(response_len) ++ response[0..response_len]).
    _pad:         40 bytes      — zero.

  request[frame_max]   — server writes CALL frames here.
  response[frame_max]  — sidecar writes RESULT/QUERY frames here.

Total region size: 64 + slot_count * (64 + frame_max * 2)
```

## CRC Convention

CRC32 (ISO 3309, same polynomial as zlib). Computed over:
```
le_u32(payload_length) ++ payload_bytes[0..payload_length]
```
The 4-byte length prefix is included in the CRC to detect corrupted
length fields (a corrupted length produces a CRC mismatch rather
than a garbage read).

## Seq Protocol

**Server writes a CALL:**
1. Write payload to `slot.request[0..len]`.
2. Set `request_len` and `request_crc`.
3. Increment `server_seq` with release-store.
4. Increment `epoch` with release-store.
5. `futex_wake(&epoch, 1)`.

**Sidecar detects a CALL:**
1. Acquire-load `server_seq`.
2. If `server_seq > last_seen_server_seq[slot]`: new CALL available.
3. Validate `request_crc`.
4. Parse frame from `slot.request[0..request_len]`.

**Sidecar writes a RESULT:**
1. Write payload to `slot.response[0..len]`.
2. Set `response_len` and `response_crc`.
3. Increment `sidecar_seq` with release-store.
4. `futex_wake(&sidecar_seq, 1)`.

**Server detects a RESULT:**
1. Acquire-load `sidecar_seq`.
2. If `sidecar_seq >= server_seqs[slot]`: response available.
3. Validate `response_crc`.
4. Parse frame from `slot.response[0..response_len]`.

Memory ordering: the release-store on seq guarantees all prior
payload writes are visible to the other side's acquire-load.

## Frame Types

### CALL (0x10) — server → sidecar

```
[tag: u8 = 0x10]
[request_id: u32 BE]
[name_len: u16 BE]
[name: name_len bytes]        — function name (e.g., "handle_render")
[args: remaining bytes]       — function-specific payload
```

### RESULT (0x11) — sidecar → server

```
[tag: u8 = 0x11]
[request_id: u32 BE]
[flag: u8]                    — 0x00 = success, 0x01 = failure
[data: remaining bytes]       — function-specific payload
```

### QUERY (0x12) — sidecar → server (worker SHM only)

Sent during worker execution when the worker calls `db.query()`.

```
[tag: u8 = 0x12]
[request_id: u32 BE]
[query_id: u16 BE]            — per-worker query counter
[sql_len: u16 BE]
[sql: sql_len bytes]
[mode: u8]                    — 0x00 = single row, 0x01 = all rows
[param_count: u8]
[params: type-tagged values]
```

### QUERY_RESULT (0x13) — server → sidecar (worker SHM only)

```
[tag: u8 = 0x13]
[request_id: u32 BE]
[query_id: u16 BE]
[row_set: remaining bytes]    — serialized rows (see Row Set Format)
```

## Type Tags

Used in SQL parameters and row set values.

| Tag | Value | Wire Format |
|-----|-------|-------------|
| integer | 0x01 | i64 LE (8 bytes) |
| float | 0x02 | f64 LE (8 bytes) |
| text | 0x03 | u16 BE length + UTF-8 bytes |
| blob | 0x04 | u16 BE length + bytes |
| null | 0x05 | 0 bytes |

## Function-Specific Payloads

### handle_render CALL args (1-RT)

```
[operation: u8]               — Operation enum value
[id: 16 bytes LE]             — entity UUID (u128)
[body_len: u16 BE]
[body: body_len bytes]        — JSON body
[row_set_count: u8]
[row_sets: ...]               — prefetch results (may be 0)
```

### handle_render RESULT data

```
[status_len: u16 BE]
[status: status_len bytes]    — status string (e.g., "ok", "not_found")
[session_action: u8]          — 0=none, 1=set_authenticated, 2=clear
[write_count: u8]
[writes: ...]                 — write_count × { u16 sql_len, sql, u8 param_count, params }
[dispatch_count: u8]
[dispatches: ...]             — dispatch_count × { u8 name_len, name, u16 args_len, args }
[html: remaining bytes]       — rendered HTML
```

### route_prefetch CALL args (2-RT first half)

```
[method: u8]                  — 0=GET, 1=PUT, 2=POST, 3=DELETE
[path_len: u16 BE]
[path: path_len bytes]
[body_len: u16 BE]
[body: body_len bytes]        — raw request body
```

### route_prefetch RESULT data (2-RT first half)

```
[operation: u8]
[id: 16 bytes LE]
[body_len: u16 BE]
[body: body_len bytes]        — JSON body (may differ from request body)
[query_count: u8]
[queries: ...]                — query_count × { mode:1, sql_len:2, sql, param_count:1, params }
[key_count: u8]
[keys: ...]                   — key_count × { key_len:1, key_bytes, mode:1 }
```

## Worker Dispatch

The worker SHM uses the same slot layout and frame format as the
request SHM. Differences:

- **Slot count**: `max_in_flight_workers` (default 16), read from region header.
- **CALL**: server sends worker function name + args.
- **QUERY sub-protocol**: during worker execution, the sidecar may
  send QUERY frames (0x12) and wait for QUERY_RESULT (0x13). The
  slot alternates between sidecar-writes and server-writes. Each
  exchange bumps the respective seq counter. See diagram below.
- **RESULT**: terminates the worker execution. Tag 0x11 marks completion.
- **Maximum QUERY round-trips**: 64 per worker execution (`queries_max`).

### Worker QUERY sequence diagram

```
Server                          Sidecar (worker slot N)
  │                                │
  ├─── CALL ──────────────────────►│  server writes slot.request, bumps server_seq
  │                                │  sidecar detects server_seq > last_seen
  │                                │  sidecar starts async worker function
  │                                │
  │                                │  worker calls db.query(sql, params)
  │◄── QUERY ─────────────────────┤  sidecar writes slot.response (tag 0x12), bumps sidecar_seq
  │                                │
  │    server detects sidecar_seq  │
  │    server executes SQL         │
  │                                │
  ├─── QUERY_RESULT ──────────────►│  server writes slot.request (tag 0x13), bumps server_seq
  │                                │  sidecar detects server_seq, reads rows
  │                                │  worker resumes with query result
  │                                │
  │                                │  (repeat for more db.query calls)
  │                                │
  │                                │  worker function returns
  │◄── RESULT ────────────────────┤  sidecar writes slot.response (tag 0x11), bumps sidecar_seq
  │                                │
  │    server detects RESULT       │
  │    worker dispatch completed   │
```

**Turn tracking**: the seq counters determine whose turn it is.
After the server bumps `server_seq` (CALL or QUERY_RESULT), the
sidecar's next write to `response` is expected. After the sidecar
bumps `sidecar_seq` (QUERY or RESULT), the server's next read from
`response` is expected. The adapter polls `server_seq` changes to
detect QUERY_RESULT arrivals.

### Worker CALL args

```
[tag: 0x10]
[request_id: u32 BE]
[name_len: u16 BE]
[name: bytes]                 — worker function name (e.g., "charge_payment")
[args: remaining bytes]       — type-tagged dispatch arguments
```

### Worker RESULT data

Same as standard RESULT frame. The `data` field contains the worker's
return value as JSON.

### Dispatch serialization (in handle_render RESULT)

When a handler calls `worker.xxx(id, body)`, the dispatch is
serialized in the handle_render RESULT's dispatch section:

```
[dispatch_count: u8]
[dispatches: dispatch_count × {
  name_len: u8
  name: name_len bytes        — worker function name
  args_len: u16 BE
  args: args_len bytes         — type-tagged arguments
}]
```

## Row Set Format

Returned in QUERY_RESULT and in handle_render CALL row sets.

```
[column_count: u16 BE]
[columns: column_count × {
  name_len: u8
  name: name_len bytes
  type_tag: u8                 — TypeTag enum value
}]
[row_count: u32 BE]
[rows: row_count × {
  values: column_count × type-tagged value
}]
```

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `frame_max` | 262144 (256 KB) | Maximum payload per slot |
| `pipeline_slots_max` | 8 (default) | Request SHM slot count |
| `max_in_flight_workers` | 16 | Worker SHM slot count |
| `queries_max` | 64 | Max QUERY round-trips per worker |
| `worker_name_max` | 64 | Max worker function name length |
| `worker_args_max` | 4096 | Max serialized worker args |
| `worker_result_max` | 4096 | Max worker result data |

## Implementing an Adapter

An adapter must:

1. **Open SHM regions**: POSIX `shm_open("/tiger-{pid}")` + `mmap`.
   Read `slot_count` and `frame_max` from the region header.
2. **Poll request slots**: scan for `server_seq > last_seen`, validate
   CRC, parse CALL, dispatch to handler, write RESULT, bump `sidecar_seq`.
3. **Handle two CALL types**:
   - `handle_render` (name = "handle_render") — 1-RT dispatch.
   - `route_prefetch` (name = "route_prefetch") — 2-RT first half.
4. **Optionally poll worker slots**: same protocol, different region.
   Worker CALLs name the worker function. QUERY sub-protocol for
   database reads during worker execution.
5. **Signal readiness**: begin responding to CALLs. The server detects
   the sidecar is alive when it receives the first RESULT.
