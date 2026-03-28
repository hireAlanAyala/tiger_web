# Load Test — Deferred Features

Remaining items from the load test implementation. The tool works
end-to-end without these — they're power user features.

## `--batch-delay` and `--print-batch-timings`

Pause between batches and log per-batch duration. Requires defining
"batch" in a pipelined connection model. TB has fixed batch sizes.
We have independent connections that pipeline continuously.

Natural batch definition: one round of completions across all
connections. After N completions (N = connections_count), pause for
`--batch-delay` ms. `--print-batch-timings` logs the time from batch
start to batch end.

This throttles load to below the server's maximum — useful for
testing sustained load at a specific rate.

### Implementation

- [ ] Add `batch_delay` and `print_batch_timings` to CliArgs and
  LoadGen (removed previously because they were accepted but ignored).
- [ ] Track batch boundaries in on_response_complete: every
  connections_count completions = one batch.
- [ ] After each batch, if batch_delay > 0, pause dispatch_all for
  the delay duration.
- [ ] If print_batch_timings, log batch index + duration.

## Rule 2: Throughput plateau detection

Requires running multiple load tests at different connection counts
and comparing throughput. Fundamentally different from the single-run
model.

Options:
- `--sweep=1,10,50,128` mode that runs multiple passes and compares
- A wrapper script that calls `zig build load` multiple times
- Post-hoc analysis from saved results

### Detection rule

If throughput at N connections ≈ throughput at 2N connections (within
5%), the tick loop is saturated. Report: "throughput plateaus at N
connections — tick loop is the ceiling."
