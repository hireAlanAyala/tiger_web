
  The architecture has handled single-entity CRUD, multi-entity transactions, filtering, and cross-cutting concerns. The remaining patterns a real web server would face are mostly
  transport-level, not state machine-level:

  - Authentication/authorization — a schema layer concern (middleware before translate)
  - Rate limiting — a commit loop concern or connection-level
  - File uploads/binary payloads — HTTP parser concern
  - Webhooks/async notifications — would stress the IO layer, not the state machine
  - Full-text search — a storage concern (SQLite FTS)

  
✓ Codec fuzzer: fuzz the JSON↔Message parsing boundary (codec_fuzz.zig)
  Found and fixed: query_param infinite loop on &&, zero-ID acceptance in create/update/transfer paths.
