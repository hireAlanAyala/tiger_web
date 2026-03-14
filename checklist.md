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

## Tests
- [ ] New operation added to auditor
- [ ] New encoding path covered by fuzzer
- [ ] New state transition exercised by sim
- [ ] Worst-case sizing validated (comptime derivation or unit test)

## Concepts
- [ ] No intermediate abstraction that just forwards a value without transforming it
- [ ] Decision made at the layer that has the information (not forwarded through a wrapper)
