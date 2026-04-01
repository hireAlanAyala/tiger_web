# Post-implementation checklist

After implementing a feature, walk through these before committing.

## Domain constraints
- [ ] Variable-length output capped by a constant in `message.zig`, not the renderer
- [ ] State machine enforces the cap; renderer asserts it
- [ ] Buffer sizes derived at comptime from the domain constant

## Assertions
- [ ] Preconditions asserted at public entry — private helpers trust the caller
- [ ] No runtime assert for something comptime can check
- [ ] No re-checking what a caller already proved (unless pair assertion from a different code path)
- [ ] Pair assertions where data flows between two code paths (write path → storage → read path). The read side asserts what the write side promised. Example: `bind_param` writes u128 as 16-byte big-endian BLOB; `read_column` asserts `column_type == SQLITE_BLOB` and `column_bytes == 16`. Catches schema drift, column reordering, or a type change on one side without updating the other.

## Tests
- [ ] New encoding path covered by fuzzer
- [ ] New state transition exercised by sim
- [ ] Worst-case sizing validated (comptime derivation or unit test)
- [ ] New type in bind_param/read_column has a fixed-input round-trip test and is covered by the seeded round-trip fuzzer
- [ ] Test assertions check the **actual system invariant**, not a proxy for it. Assert on the system's real output contract (response body content, database state, observable side effects) — never on implementation details or assumed protocol behavior that the system doesn't actually use. A test that checks a proxy can pass for months while hiding a real bug, and actively misdirects debugging toward phantom infrastructure issues.
  - Case study: a sim test used HTTP status codes (404 vs 200) to distinguish "delete won" from "update won" in a race. The server always returns 200 — status is in the body. The 404 branch was dead code. The test only passed when the update won the race, and the failure was misdiagnosed as a SimIO multi-connection bug for an entire debugging session. Fix: check `body_contains("Product not found") or body_contains("Updated")` — the actual observable contract.

## Concepts
- [ ] No intermediate abstraction that just forwards a value without transforming it (exception: capability restriction wrappers like ReadOnlyStorage that subtract methods are structural, not indirection)
- [ ] Decision made at the layer that has the information (not forwarded through a wrapper)

## Hardening

After the checklist passes, do two focused passes:

**Assertions pass.** Read the code and inventory every invariant the code assumes during execution. If an invariant isn't asserted at the correct outermost boundary, add an assertion. Inner code should be able to trust outer assertions. Then review: what would the TigerBeetle team say about these assertions?

**Test pass.** Look for code that would benefit from:
- Fixed-input unit tests — prevents regression on known cases
- Seed unit tests — finds unhandled edge cases when input data is unpredictable
- Simulation tests — ensures integration across the full stack

## Audit (periodic)

Derived from SQLite's testing page, filtered through TB's principles. These aren't per-feature checks — run them periodically against the whole codebase.

### Function length (70-line limit)
- [ ] No function in `state_machine.zig`, `server.zig`, `connection.zig`, `storage.zig`, `app.zig` exceeds 70 lines. TB: "Art is born of constraints." If a function is too long, centralize control flow in the parent and move non-branchy logic to helpers.

### Hot-loop extraction
- [ ] Hot loops use standalone functions with primitive args (no `self`). TB: "the compiler doesn't need to prove that it can cache struct's fields in registers." Check `server.zig` tick, `connection.zig` recv/send paths, `state_machine.zig` prefetch/execute.

### Argument passing
- [ ] Function args > 16 bytes passed as `*const` when the callee doesn't need a copy. Prevents accidental stack copies and catches caller bugs where an alias is mutated mid-call.

### In-place construction
- [ ] Large structs initialized in-place via out-pointer (`fn init(target: *Self) void`), not returned by value. Prevents intermediate copies and assumes pointer stability.
