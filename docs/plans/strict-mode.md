# Strict Mode

Opt-in annotation modifier that enables additional scanner and compiler validation. Not required — the default behavior is permissive. Users who want tighter guarantees opt in per-annotation.

## Activation

Strict mode is per-annotation, not global. Add `@strict` to any annotation:

```
// [handle] .get_product @strict
// [handle] .create_product @strict
```

## What strict enables

### `[handle] @strict`

- **Skipped handle must use `@read-only`.** Without strict, a `[handle]` with no function body is silently treated as read-only. With strict, the scanner rejects a bodyless `[handle]` unless it explicitly says `@read-only`:

```
// [handle] .get_product @strict @read-only    (accepted)
// [handle] .get_product @strict               (scanner error — missing @read-only or function body)
```

- **Mutations must have function body.** `@strict` on a `[handle]` with `@read-only` that the compiler determines has write semantics (e.g., operation produces ExecuteResult with writes) is a compile error. Belt and suspenders.

### Future strict checks (as needed)

- `[render] @strict` — require exhaustive status handling (every Status variant explicitly matched, no catch-all)
- `[route] @strict` — require explicit rejection logging for unmapped paths
- `[prefetch] @strict` — require all Prefetch struct fields populated in every return path (compiler already catches this for struct literals, strict could extend to conditional paths)

## Design principles

- Strict is always opt-in. Default behavior doesn't change.
- Strict never changes runtime behavior — only adds validation.
- Strict modifiers are greppable: `grep "@strict"` finds all strict annotations.
- Strict can be applied per-annotation, not just per-file or per-project. Granular control.
- New strict checks can be added over time without breaking existing handlers.
