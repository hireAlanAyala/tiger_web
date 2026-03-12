questions
- would SSE connections count towards the connection slots?
- put nginx in front of server?

remaining patterns (transport-level, not state machine-level):
- rate limiting — a commit loop concern or connection-level
- file uploads/binary payloads — HTTP parser concern
- webhooks/async notifications — would stress the IO layer, not the state machine
- full-text search — a storage concern (SQLite FTS)
