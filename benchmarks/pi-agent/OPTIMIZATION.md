# Schema reuse and result quality

This records the cache-only stage. Subsequent live-model findings are in
[the live quality and speed report](live/REPORT.md).

## Implemented optimization

Alloy now retains resolved schemas in agent state and reuses them when the
exact input schema matches. Entries are refreshed before tool execution; changed
schemas are resolved and validated normally, removed tools are discarded, and
required-key mode clears the cache on the next tool batch. The cache does not
retain previous versions, introduce a global service, or appear in Result or
session metadata. Execution functions and arguments are never cached.

This preserves strict validation, local-reference restrictions, duplicate-key
rejection, middleware order and normal tool execution. Direct executor calls
still validate independently against the current tool schemas.

The profile isolates schema resolution at roughly 850 microseconds, versus
below one microsecond for validating this simple input against a resolved schema.
Those are fixture-specific measurements with microsecond timer granularity;
see the recorded mean as well as the median. Schema resolution includes checking
the schema against its meta-schema, which is retained for every changed schema.

## Measurements

Same 18 scenarios, three fresh-process repetitions per engine, 100 measured
samples per scenario per process. Before/after were separate local runs, not
interleaved randomized trials. Treat small differences as timing variation.
Medians below are in milliseconds.

| Scenario | Alloy before | Alloy after | Pi rerun |
|---|---:|---:|---:|
| One tool + final response | 0.905 | 0.935 | 0.041 |
| Ten tool rounds | 8.945 | 1.297 | 0.117 |
| One tool, required-key validation | 0.030 | 0.033 | 0.042 |
| Ten rounds, required-key validation | 0.287 | 0.309 | 0.137 |

Ten full-schema tool rounds improved **6.9×**, or **85.5% less time**.
The first schema resolution remains, so there is no meaningful one-shot gain.
Pi still has lower overhead on the equal-validation workloads. Required-key
rows perform less validation in Alloy and are not equal-work comparisons.
I/O fluctuations are not attributed to this change: one-batch I/O cases do not
reuse schemas within a run.

All 18 benchmark scenarios retained their expected outcomes. The full CI run
passed **1,038 tests**, **91.33% coverage**, Credo and Dialyzer. New tests cover
same-name schema changes, dynamic request preparation, removal/disabled
validation, forbidden remote references, ambiguous keys and cache exclusion
from returned metadata. Documentation also builds with warnings as errors.

## Result quality

**Answer quality has not been measured.** These fixtures supply predetermined
model replies, and therefore cannot measure reasoning, factual accuracy,
coding success or model-driven tool selection. Their success establishes only
the checked execution behavior.

Schema reuse changes no model-visible contract intentionally. Every tool input
is still validated, and schemas are re-resolved when changed. The deterministic
outcomes remained unchanged; there is no mechanism here intended to trade answer
quality for speed, but this is not a live-model quality result.

The existing Pi/Alloy differences can affect live outcomes: coercion can avoid
an extra correction turn but accepts transformations Alloy rejects; stopping
after a tool can avoid another model request but must only be enabled when that
tool supplies the intended final answer. Neither policy is universally better.
The runtime language alone does not establish which produces better answers.

A useful live comparison should use the same pinned model, prompt, tool
schemas, tool data, context budget and stopping policy. Compare equivalent
policies first; evaluate deliberate defaults separately. Record actual
provider requests so differences in transcript construction are visible.
Use representative tasks with objective outcomes (passing code tests, exact
extracted fields, correct tool side effects), multiple paired attempts, and
blind scoring only where objective checks are insufficient. Report task
success, wrong actions, retries, model requests, tokens/cost and end-to-end
latency. Scripted-loop speed cannot substitute for these scores.

## Next priorities

1. Measure live task success and end-to-end latency before more micro-optimization.
2. Investigate redundant context/token volume and avoidable model rounds only
   with task-success checks guarding against quality regressions.
3. Keep concurrency explicitly limited to independent tools. Do not increase
   concurrency for order-dependent side effects merely to improve a benchmark.
4. Consider shared schema compilation only if profiling real workloads shows
   repeated short-lived runs make first-use cost material. State-local reuse
   keeps lifecycle and invalidation simple today.

## Reproduce and inspect

- [Runner and methodology](README.md)
- [Baseline source manifest and samples](results-before-schema-cache/summary.json)
- [Current source manifest and samples](results/summary.json)
- [Component benchmark](components.exs)
- [Historical schema profile](results/schema-profile.txt)
- [Architectural decision](../../docs/adr/0002-composable-loop-controls.md)
