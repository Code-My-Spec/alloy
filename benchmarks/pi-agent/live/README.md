# Paired live quality and speed evaluation

This exercises the native Gemini streaming provider in both Alloy and Pi Agent
Core 1.2.0. It uses synthetic records only. It does not run model-written code,
send messages, or mutate external applications.

## Protocol

- Fixed requested model: `gemini-2.5-flash`; responses retain `modelVersion`.
- Temperature 0, thinking budget 0, 512 output tokens, maximum eight model
  requests per task, equal system instructions and tool schemas. Temperature 0
  does not make a hosted model deterministic.
- Twelve tasks in four categories: lookup/arithmetic, constrained selection,
  extraction with an embedded untrusted instruction, and dependent lookups.
  Three numeric variants per category are not twelve independent domains.
- Two repeats of every task in each of four conditions: Alloy/Pi × normal
  completion/stop after successful `submit_answer`. Total: 96 runs.
- Seeded randomized condition order within each task/repeat block. Both workers
  stay running; imports/startup are outside timing. The initial request can
  still incur first-use costs. There is no live warmup excluded from the main
  sample; raw ordering permits sensitivity checks.
- One condition at a time. Both adapters stream through the same local proxy,
  which forwards canonical JSON (sorted keys) without changing values. This
  removes serializer key-order differences while retaining native transcript
  semantics, such as tool-result envelopes. These are adapter-inclusive runs,
  not byte-identical transcript experiments.
- The proxy checks generation settings and records request bodies, raw streamed
  responses, HTTP status, provider wall time, token usage and model version.
  Headers and API credentials are never persisted. Workers use a dummy key;
  only the proxy receives the real key from the parent environment.
- The proxy currently opens a fresh TLS connection per request in both arms.
  Therefore absolute latency includes a shared measurement-proxy transport cost;
  do not describe it as direct production-client latency. Saving a request also
  saves this overhead. Provider wall time includes that connection cost.
- Main run limits: 900 requests and $2 estimated Standard-tier token cost, with
  a maximum eight requests per task. Paid-tier estimates may differ from actual
  charges; free-tier usage and other billing adjustments are not inferred.
- Infrastructure/configuration failures stop the run and retain partial data.
  Failed model tasks remain in the scored sample. Preflight attempts are retained
  under `smoke*` and excluded from the main sample; they include the reproduced
  Gemini schema-field compatibility failure and configuration debugging.

## Quality metrics

`final_correct` requires exact parsed-JSON equality with independently specified
expected data. `success` additionally requires one correct submission, use of
lookup and calculator tools, no tool errors and a successful runtime outcome.
Wrong submissions and tool errors are recorded separately. A correct final answer
after an invalid tool call can count as final-correct while failing the stricter
clean-execution metric. The evaluator never tells the model the expected answer.

This suite measures a narrow structured-tool workload. It cannot establish coding,
research, long-context, multimodal, swarm or general agent quality. Repeated variants
and a small sample do not establish statistical equivalence. Success intervals use
Wilson binomial intervals (descriptive; repeated task outcomes are correlated).
Latency differences use paired observations and a bootstrap resampling whole tasks.

The stopping experiment is valid because the submitted JSON is explicitly the
whole deliverable. Do not generalize it to tasks requiring further synthesis,
verification or unresolved side effects.

## Reproduce

From the repository root, with `GEMINI_API_KEY` or `GOOGLE_API_KEY` in the environment:

```sh
npm ci --prefix benchmarks/pi-agent --ignore-scripts --no-audit --no-fund
mise exec -- mix compile --warnings-as-errors
LIVE_OUTPUT=results-new python3 benchmarks/pi-agent/live/run.py
python3 -m unittest discover -s benchmarks/pi-agent/live -p 'test_*.py'
```

Each output directory must be new, preserving earlier evidence. Optional
`LIVE_TASK_LIMIT` and `LIVE_REPEATS` reduce a smoke run; the default is the full
12 tasks × 2 repeats × 4 conditions. The output manifest retains source hashes,
configuration, cost rates and the base commit. Local modifications are included
in source hashes; the base commit alone does not identify the tested code.

[Google pricing](https://ai.google.dev/gemini-api/docs/pricing) supplies the
Standard-tier rates used for estimates: $0.30/M input, $0.03/M cached input and
$2.50/M output, including thinking tokens. Verified on 2026-10-13.

## Follow-up experiments

The `contract` experiment uses `holdout.json`, with new numbers and lookup keys.
It compares the original lookup schema with a schema whose `key` parameter has
an enum of the records actually available to that run. Both arms stop after the
final-answer tool. No expected output is added to a model request. Run with:

```sh
LIVE_OUTPUT=holdout-new LIVE_TASK_FILE=holdout.json LIVE_EXPERIMENT=contract python3 benchmarks/pi-agent/live/run.py
```

`ablation.py` uses one recorded development request and changes result envelopes,
IDs, or system/auto fields independently, with three randomized repetitions.
It tests the immediate next tool call; it is not a whole-task quality evaluation.
Its evidence motivated the provider result-envelope change.

Final confirmation uses `confirmation.json` (both 12-task sets), the key enum,
stop-after-final-tool, and the updated provider. It is a regression confirmation
on known task families, not another untouched holdout or proof of generalization:

```sh
LIVE_OUTPUT=confirmation-new LIVE_TASK_FILE=confirmation.json LIVE_TASK_LIMIT=24 LIVE_REPEATS=1 LIVE_EXPERIMENT=confirmation python3 benchmarks/pi-agent/live/run.py
```

Use `analyze.py OUTPUT_DIRECTORY` for the primary quality/speed comparison. It
reports correct final answers separately from clean execution and computes
paired latency only where both compared conditions succeeded. The runner's
`summary.json` also retains unconditional timings, which include fast failures
and must not be used alone to rank the runtimes.
