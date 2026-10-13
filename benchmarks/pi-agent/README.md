# Alloy and Pi Agent comparison

A deterministic comparison of the real Alloy loop and Pi Agent Core 1.2.0.
It checks behavior and measures local execution time without model API calls.

## Run

From the Alloy repository root:

```sh
npm ci --prefix benchmarks/pi-agent --ignore-scripts --no-audit --no-fund
mise exec -- mix deps.get
mise exec -- mix compile
python3 benchmarks/pi-agent/run.py
```

Requires Node >=22.19, Python 3, and the repository's pinned Elixir/OTP toolchain.
The npm dependencies belong only to this benchmark; Alloy gains no runtime
dependency on Pi. The committed npm lockfile pins the installed dependency tree.

The runner performs three fresh-process repetitions, alternating engine order.
Each process warms up every scenario 20 times, then records 100 samples.
Override with `BENCH_REPEATS` and `BENCH_SAMPLES`. Results overwrite
`results/*`; run engines sequentially on an otherwise idle machine.

## Scope and method

- Both engines receive the same scripted prompts, tool batches, inputs and
  schemas from `fixtures.json`. Neither adapter makes network requests.
- Alloy uses `Alloy.run/2`; Pi uses `runAgentLoop` with an injected response
  stream and a no-op event sink. This is a comparison of these public loop
  paths, not an isolated comparison of equivalent internal instructions.
- Main comparisons enable Alloy's optional schema validation; Pi validates
  schemas by default. Parallel batches permit all eight calls in both engines.
  The `*_required` scenarios measure Alloy's normal required-key-only mode;
  Pi still performs full schema validation. Those rows are diagnostic and
  must not be presented as equal-validation speed comparisons.
- Each sample creates fresh tools and run state, executes the loop, and
  normalizes its result. Startup, imports, compilation, warmup and file output
  are excluded. Pi can reuse its compiled validator within a multi-turn run;
  Alloy reuses resolved schemas in agent state when their exact contents match.
- The adapters check deterministic outcomes on every sample. The Python runner
  independently checks expected request counts, actual tool invocation counts,
  result IDs, source order, error flags and successful result contents.
  Provider-specific error wording is normalized to `<error>`.
- I/O scenarios use eight 5 ms timers. Timer resolution differs between BEAM
  and Node; these measure observed wall time, not exactly 40 ms of work.
- `agents_32_io` starts 32 independent runs concurrently, each executing four
  5 ms tools in parallel. Its time is for the whole group. Alloy uses Tasks;
  Pi uses Promise.all. There is no cross-agent communication or coordination.
- Raw samples, per-process medians, pooled medians/p95s, runtime versions,
  source hashes and the Alloy base commit are retained in `results/`.
  Alloy includes local uncommitted changes; the base commit alone does not
  identify the tested implementation.

## Expected differences

1. Numeric-string input: Pi coerces `"1"` to integer `1`; Alloy's schema mode
   rejects it before execution.
2. Mixed early-stop batch: Alloy's `stop_after_tool: "work"` stops after the
   selected successful call and completion of the whole batch. Pi's
   `terminate` hint must be true for every result. In the fixture, only
   `work` receives that hint, so Pi makes one more model request.
3. Early-stop behavior is configured through different APIs: the Pi adapter
   sets `terminate` only on successful `work` results. This is an adapter
   policy, not a claim that Pi cannot terminate after a failure.

The runner fails on any unlisted difference. Timing rows with different
behavior or validation policies should not be used for direct speed ratios.

## Limits

This does not test model quality, provider HTTP implementations, streaming
token latency, memory usage, CPU-bound tools, distributed operation, crash
recovery, durability or realistic swarm coordination. Request preparation,
argument editing, transcript repair and cancellation remain covered by
Alloy's own tests; this harness does not establish cross-library equivalence
for them. Matching these fixtures is not full Pi compatibility.

See [recorded findings](REPORT.md) for the measured results and interpretation.

The original measurements are preserved in `results-before-schema-cache/`.
See [optimization and quality findings](OPTIMIZATION.md) for the current changes.

For measured model task quality and end-to-end speed, see the
[live evaluation](live/README.md) and its [findings](live/REPORT.md).
