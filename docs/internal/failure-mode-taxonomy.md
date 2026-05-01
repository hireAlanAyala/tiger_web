# Failure Mode Taxonomy

The framework's success modes are documented elsewhere. This doc is for what
the framework refuses to let happen, what it doesn't catch, and where the
sharp edges are. A framework you can pitch is one whose failure modes you
can name precisely.

Each entry: **the problem first**, then a brief defense. Solutions are
declared, not exhaustively specified — the point is to make the failure
visible, not to pretend it's solved.

---

## 1. Entity dissolution

**The problem.** The framework's primitives — commands, conditional UPDATEs,
worker dispatches — bias toward command-pipeline style. Each operation
gets its own handler file: `pay_claim.js`, `pay_settle.js`,
`void_claim.js`, `void_settle.js`. Co-location is by *operation*, not by
*entity*.

Under deadline pressure, the natural place to put each invariant check is
*in the handler that needs it*, because that's where the data is flowing.
Six months later, the rule "void requires paid" lives half in
`void_claim.js`, half in scattered `WHERE` clauses, half in a worker no
one remembers writing. The entity that should own its invariants has
dissolved into the workflow.

This is the same pathology that kills Step Functions / Temporal /
Camunda projects at scale: behavior co-locates with execution rather
than with the thing it constrains. The entity becomes a dumb bag of
fields. Cohesion is gone. Adding a new state means grepping for every
`WHERE payment_status = …` across the handler tree and praying.

**Why the framework doesn't structurally prevent it.** Every handler can
call `db.execute("UPDATE …")`. There is no aggregate root, no private
setter, no compiler-enforced "only the entity mutates itself." Cohesion
is a code-review concern, not a language concern.

**When it bites.** Year 2, ~50 handlers in, no `domain/` module
extracted, a new team member adds a status value and the existing
transition guards silently fail to cover it.

**Defense (declared, not enforced).**

- Adopt **functional-core / imperative-shell**: one `domain/<entity>.js`
  module per entity, holding pure `decide(state, command) → result`
  functions and the legal-transitions table. Handlers call `decide`,
  apply the result via conditional UPDATE, dispatch workers. Handlers
  orchestrate; they do not legislate.
- The convention is **deferrable**: start with inline UPDATEs when the
  domain is small, extract to `domain/` once the entity has shape. The
  refactor is mechanical because handlers were already thin.
- Eventual tooling: lint rule banning raw mutations of state columns
  outside the entity's `domain/` module. Not built yet; named here so
  it doesn't get forgotten.

The failure mode is real and the framework can't catch it. Naming it
loudly and making the disciplined path the easy one is the entire
defense.

---
