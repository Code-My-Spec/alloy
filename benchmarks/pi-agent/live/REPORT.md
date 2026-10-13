# Live quality and speed benchmark — 2026-10-14

These measurements used the recorded 0.12.5-based development source, before
reconciliation with 0.13. They are not performance measurements of the 0.13 release.

Alloy and Pi Agent Core 1.2.0 both passed all 24 tasks in final confirmation,
with no invalid tool calls or wrong submissions. Median end-to-end latency was
5.99 s for Alloy and 6.15 s for Pi.
The paired latency confidence interval spans zero: this sample does not establish
an end-to-end speed winner. Pi retains much lower cold-loop overhead.

The work comprises **240 scored live runs**, **15 controlled single-request
probes**, and separate retained preflight attempts. It uses Gemini 2.5 Flash,
four synthetic task families, native provider adapters and objectively checked
JSON answers. This is a reproducible narrow agent-loop evaluation, not a coding
benchmark, a production workload guarantee or proof of general quality parity.

## Why Pi is faster locally

On the same Apple M4 Pro, warmed component measurements were:

| Component | Alloy median | Pi median |
|---|---:|---:|
| Cold schema preparation | 874.96 µs | 10.67 µs |
| Tool execution with cached schema | 18.04 µs | 1.71 µs |

Alloy resolves and validates a schema against its meta-schema. Pi compiles a
TypeBox validator; its measured cold operation also performs an argument check.
These are real implementation paths, not identical instructions. Warm resolved
argument validation itself was only 0.54 µs in Alloy; the old repeated preparation
was the expensive step. State-local schema reuse already removed that repetition.

Alloy’s executor includes supervised tasks, timeout handling, caller-death cleanup,
events and result assembly. The Pi single-tool helper measured here uses Promises
and omits lifecycle events. A bare supervised Task measured 3.04 µs, versus 0.17 µs
for a Promise. This explains part of the dispatch gap without establishing a
general BEAM-versus-JavaScript performance ranking. Preserve these guarantees; the
live measurement puts over 99% of elapsed time in provider/transport work.

## What changed

1. **Correct Gemini tool-schema field.** A real HTTP 400 exposed Alloy sending
   `additionalProperties` in the OpenAPI-shaped `parameters` field. The adapter
   now uses `parametersJsonSchema`. Updated regression tests failed before the
   fix and passed after it.
2. **Preserve tool text in explicit result envelopes.** Gemini success results
   now use `{"output": original_text}` and errors use `{"error": original_text}`.
   JSON-looking text is no longer decoded into arbitrary response fields. This
   matches Pi’s framing and reduces adapter code. Public transcript content and
   structured metadata are preserved.
3. **Make lookup keys explicit in the application tool schema.** The improved
   benchmark tool exposes the available record keys as an enum. It reveals the
   permitted interface, never the expected answer. This remains application policy.
4. **Stop after a complete final-answer tool.** Both engines use their existing
   opt-in stopping controls when the submitted JSON is the complete deliverable.
   This remains opt-in, and is not appropriate when further synthesis is required.

The provider changes add no runtime dependency or service. Task supervision,
cancellation, local validation and the minimal agent-loop boundary are preserved.

## Controlled diagnosis

One development case repeatedly called a nonexistent `multiply` tool after
Alloy returned lookup results. We replayed its request with one representation
change at a time, three times per condition in randomized order:

| Request representation | Correct next tool call |
|---|---:|
| Original Alloy | 0/3 |
| Change only result envelope | 3/3 |
| Remove generated IDs only | 0/3 |
| Change system/auto fields only | 0/3 |
| All three changes | 3/3 |

These probes use non-streaming GenerateContent and score the immediate next call,
not the whole task. The main evaluations use streaming. The final confirmation
checks the adopted envelope through the complete native streaming loop. The old
result shape is legal under Google’s API; its model behavior motivated the change.

## Quality experiments

“Correct” means exact parsed-JSON equality with the expected answer. “Clean”
additionally requires exactly one correct submission, required lookup/calculator
use, no tool errors, and a successful runtime outcome. Failed tasks remain in
the sample. Expected answers are withheld from the model.

### Initial 96-run stopping experiment

Twelve tasks × two repeats × two engines × two stopping policies. Schema-field
compatibility was fixed before this scored experiment; result-envelope behavior
was still unchanged. Both stopping policies had the same correctness counts:

| Engine | Correct and clean per policy | Primary failure |
|---|---:|
| Alloy | 16/24 | Ambiguous lookup keys; one arithmetic case failed twice |
| Pi | 18/24 | Ambiguous lookup keys |

For pairs where both policies succeeded, stopping after the final-answer tool
saved Alloy a mean **1.66 seconds** (exploratory task-bootstrap 95% interval:
1.20–2.23 seconds). Pi saved a mean **1.00 second** (0.21–2.01 seconds). These
are workload-specific savings, including the shared proxy’s per-request overhead.
Paired successful completion-mode latency did not establish an engine winner.

### 96-run lookup-contract holdout

New numeric/key variants, same four task families; both engines stop after the
final-answer tool. This experiment still used Alloy’s previous result envelope.

| Engine / lookup schema | Correct answers | Clean execution |
|---|---:|---:|
| Alloy / plain key | 18/24 | 18/24 |
| Alloy / available-key enum | 24/24 | 22/24 |
| Pi / plain key | 18/24 | 18/24 |
| Pi / available-key enum | 24/24 | 24/24 |

The enum eliminated the dependent-lookup failures in these variants. Alloy still
recovered from an invalid tool call twice; a correct final answer did not hide
those execution failures. This finding supported testing the result-envelope
change across the whole suite.

### Final 48-run confirmation

Both 12-task sets, one run per task/engine, key enum and stop-after-final-answer
enabled, with the updated Alloy provider. These are now known task families;
confirmation is not another untouched holdout.

| Metric | Alloy | Pi |
|---|---:|---:|
| Correct answers and clean execution | 24/24 | 24/24 |
| Median latency | 5.99 s | 6.15 s |
| p95 latency | 8.25 s | 7.57 s |
| Model requests, all 24 tasks | 110 | 114 |
| Input tokens | 39,957 | 41,433 |
| Output tokens | 2,511 | 2,511 |
| Standard-rate token-cost estimate | USD 0.01826 | USD 0.01871 |

The paired mean Alloy-minus-Pi latency was -0.188 s; its
exploratory task-bootstrap 95% interval was [-0.583, 0.159] s.
It spans zero. Alloy’s slightly lower median and Pi’s lower p95 do not establish
a reliable ranking. All 24 successes also do not prove 100% population accuracy:
even the descriptive binomial interval is approximately 86–100%, and related
variants weaken generalization further.

## Method and limits

- Same requested model and settings: temperature 0, thinking budget 0, output
  cap 512, maximum eight model requests. Captured model versions: `gemini-2.5-flash`.
- Randomized condition order within each task/repeat block; one live condition
  at a time. Worker processes stay running; startup is outside timing.
- Native request bodies are captured and sent through a common proxy with sorted
  JSON keys. Transcript semantics remain adapter-owned. This is an end-to-end
  adapter comparison, not a claim of byte-identical model context.
- Each proxy request opens a fresh TLS connection. Absolute latency includes
  that shared instrumentation overhead; request savings also save this overhead.
- Four synthetic task families, one model, bounded contexts, mostly simple
  arithmetic. No coding repository, freeform research, distributed swarm,
  crash-recovery or durability claim is supported.
- Success latency is reported separately from fast failures. Paired latency
  comparisons require success in both conditions. Task-bootstrap intervals are
  exploratory; variants within a family are related.
- Preflight errors and all failed scored runs are retained. There is no hidden
  retry-until-pass selection. Final confirmation follows observed development
  and holdout behavior and must not be presented as blind validation.
- Total Standard-rate estimate including preflights and probes: **USD 0.1901**.
  This is a token-price estimate, not an invoice or proof of an actual charge.

## Verification and remaining work

Full `mix ci`: **1,039 tests passed**, **91.39% coverage**, compilation, formatting,
Credo and Dialyzer passed. Documentation built with warnings as errors. Seven
offline evaluator tests cover scoring, error accounting and cost calculation.
Gemini tests cover the schema field and preservation of JSON-looking tool text
in success/error envelopes. All changes remain local and uncommitted.

The next useful extension is a representative application task set on additional
models, with artifact/tests-based scoring for code and sourced-answer checks for
research. Further local executor optimization has much less measured leverage
here than reliable tool contracts and fewer unnecessary model requests.

## Evidence and reproduction

- [Protocol and commands](README.md)
- [Machine/runtime and dependency versions](environment.json)
- [Initial live analysis](results/quality-speed.json)
- [Holdout analysis](holdout-results/quality-speed.json)
- [Confirmation analysis](confirmation-results/quality-speed.json)
- [Controlled ablation data](ablation-results/runs.json)
- [Alloy component samples](../results/components-alloy.json)
- [Pi component samples](../results/components-pi.json)
- [Provider decision](../../../docs/adr/0003-gemini-tool-wire-format.md)
- [Google request/response schema](https://ai.google.dev/api/generate-content)
- [Google Standard-tier pricing](https://ai.google.dev/gemini-api/docs/pricing)
