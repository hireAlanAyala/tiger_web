# Performance regression prevention

Ensure every layer we control has a benchmark or assertion that
catches regressions before they ship.

## Layers we control

| Layer | Has benchmark? | Has CI gate? |
|---|---|---|
| Zig HTTP parser | ❌ | ❌ |
| Zig SQLite layer | ✅ `zig build bench` | ❌ |
| Zig framework tick loop | ✅ `zig build bench` | ❌ |
| Binary protocol | ✅ fuzz smoke | ❌ |
| QUERY sub-protocol | ✅ fuzz smoke | ❌ |
| Sidecar TS runtime | ✅ `--log-trace` (manual) | ❌ |
| Concurrent pipeline | ✅ sim throughput assertion | ❌ |
| Connection handling | ✅ sim tests (fault injection) | ❌ |
| WAL recording | ✅ `zig build bench` (write path) | ❌ |
| Tracer | ❌ | ❌ |
| Annotation scanner | ❌ | ❌ |
| Auth (cookie/session) | ❌ | ❌ |
| Render encoding | ❌ | ❌ |
