# Handler API Decisions

## db.execute over writes array

The old design returned `ExecuteResult { .response, .writes }` with
a tagged union (`Write { .put_product, .update_product, ... }`). This
looked inspectable but nobody inspected it — no test asserts on the
writes array. The fuzzer and auditor check outcomes: "I created a
product, can I get it back?" They query the database after commit.

`db.execute` with SQL replaces the tagged union with the actual
mutation. Assert outcomes, not mechanics. The writes array was
mechanics. The database state after commit is the outcome.

## Write queue, not direct execution

Handle calls `db.execute` but it doesn't execute SQL immediately. It
records SQL + params into a write queue. The framework drains the queue
after handle returns, inside the transaction.

Why:
- **Handle stays deterministic.** Same context → same queue + same
  status. No IO during handle.
- **Framework owns transactions.** All writes in a tick share one
  begin_batch/commit_batch.
- **Uniform API.** Zig-native and sidecar handlers write the same code.

## No await, no async, no callbacks

The tick model eliminates async/await:
- Storage busy → prefetch returns null, retry next tick
- Worker pending → prefetch returns null, retry next tick
- Post-commit external calls → worker polls, posts result as new request

Same mechanism for all three. The single-threaded event loop does the
scheduling. External API calls (Stripe, Auth0) are handled by the
worker process, not by callbacks in handle.

## Handle is not pure

Handle has a side channel — the write queue. You can't test it by
just checking the return value. In practice, this doesn't matter.
The real tests are end-to-end (sim tests query DB after commit).
The queue is deterministic (same input → same queue). It's
structurally the same as returning a writes array, with better
ergonomics.

## Handle returns just the status

No writes array. No session field. No response wrapper. Session
changes are writes — `db.execute("INSERT INTO sessions ...")`.
The framework reads session state from the database, not from
handle's return value. (Session as writes is deferred — only
logout uses session_action currently.)
