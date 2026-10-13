# Pi Agent comparison baseline — 2026-10-13

These measurements used the recorded 0.12.5-based development source, before
reconciliation with 0.13. They are not performance measurements of the 0.13 release.

All 18 deterministic scenarios passed their engine-specific expectations across
three fresh-process repetitions: 300 measured samples per scenario per engine,
plus warmups. Sixteen scenarios produced matching normalized outcomes; two
confirmed documented semantic differences. This is bounded behavioral evidence,
not full compatibility or a live-model quality evaluation.

This report records the pre-optimization baseline. See [schema reuse results](OPTIMIZATION.md)
for the subsequent implementation and measurements.

## Tested versions

- Alloy: local loop-modernization changes on base commit
  `0bdecda62903665f0d2c8fec82ae3fa1810b9cab`; source hashes are in the result manifest.
- Pi: latest published `@earendil-works/pi-agent-core@1.2.0`, verified against
  the npm registry on 2026-10-13. The old `@mariozechner/pi-agent-core` scope
  still reports 0.73.1 and was not used.
- Upstream main: `f13c00fb3a4d77ad3faa815057e31d614d42b3f1`.
  The installed agent-loop and types source-map contents matched those source
  files exactly at this commit. This check does not claim every transitive
  dependency equals upstream main.
- Apple M4 Pro, arm64, macOS 27.0.1; Elixir 1.20.4 / OTP 28, 12 schedulers;
  Node v26.4.0.

## Timing

Pooled median and p95 wall times in milliseconds. Schema validation enabled
in both engines in this table. Timings include fresh run/tool setup and result
normalization but exclude process startup and compilation.

| Scenario | Alloy median | Pi median | Alloy p95 | Pi p95 |
|---|---:|---:|---:|---:|
| Text only | 0.004 | 0.010 | 0.013 | 0.014 |
| One tool + final response | 0.905 | 0.041 | 1.009 | 0.055 |
| Ten successive tool rounds | 8.945 | 0.114 | 9.553 | 0.233 |
| Eight tools, sequential | 1.004 | 0.039 | 1.191 | 0.053 |
| Eight tools, parallel | 0.996 | 0.040 | 1.193 | 0.060 |
| Eight 5 ms tools, sequential | 52.870 | 46.387 | 56.080 | 49.538 |
| Eight 5 ms tools, parallel | 9.219 | 6.142 | 12.127 | 6.698 |
| 32 agents × four 5 ms tools, parallel | 11.879 | 9.650 | 12.069 | 12.455 |

The 32-agent row measures completion of the whole group, not one agent.
Timer granularity and machine scheduling affect the I/O rows. The raw results
retain every sample and each process median; these are local observations,
not portable performance guarantees.

## What the measurements suggest

**The default Alloy loop has little overhead in these fixtures.** With its
normal required-key-only validation, the one-tool median was
0.030 ms and ten rounds took
0.287 ms.
That is a diagnostic baseline, not equal validation work: Pi still validates
the complete schema. Node timings also varied by scenario position and process,
so very small differences should not be treated as meaningful rankings.

**Optional full-schema validation is the clearest optimization candidate.**
Changing only Alloy’s validation mode raised the one-tool median to
0.905 ms and ten rounds to
8.945 ms.
Source inspection shows Alloy resolves schemas every tool batch while Pi
caches compiled validators by schema identity. The measurements isolate the
validation mode’s total cost; they do not separately profile schema resolution
versus argument validation. A small follow-up could measure those components
and reuse resolved schemas while the configured tool set is unchanged.
Any cache must be invalidated when request preparation replaces tools.
No production optimization was made as part of this comparison.

**Both runtimes handle concurrent waiting tools.** The timer workloads show
the benefit of parallel execution in both. Pi was faster in this particular
32-agent fixture. It contains no agent messaging, failures or supervision;
it supplies no evidence that an OTP swarm is faster or more resilient.
Those questions need a separate failure/recovery and coordination experiment.

## Behavioral findings

- Text completion, tool iteration, source-ordered batch results, sequential
  and parallel work, invalid arguments, blocking, redaction, tool failure,
  single-tool early completion and failed-stop behavior matched the fixture
  expectations.
- Numeric-string input: Pi coerced `"1"` to `1` and executed; Alloy schema
  mode rejected it and did not execute.
- Mixed early-stop batch: both finished both tools. Alloy stopped after the
  selected successful tool; Pi made a second request because only one result
  carried its termination hint. Pi can express other stopping policies; this
  is a difference between the specific APIs exercised here.
- Preparation, argument editing, transcript repair and cancellation were not
  compared across libraries. Existing Alloy tests cover these locally.

Keep the minimal architecture. Preserve the explicit validation and early-stop
semantics; document them instead of pursuing behavior parity by default.
The only performance follow-up justified here is investigating schema reuse.
No durability or swarm framework is warranted by these measurements.

## Evidence

- [Harness and reproduction instructions](README.md)
- [Raw results and source manifest](results-before-schema-cache/summary.json)
- [Pi agent loop at the checked upstream commit](https://github.com/earendil-works/pi/blob/f13c00fb3a4d77ad3faa815057e31d614d42b3f1/packages/agent/src/agent-loop.ts)
- [Published package](https://www.npmjs.com/package/@earendil-works/pi-agent-core/v/1.2.0)
