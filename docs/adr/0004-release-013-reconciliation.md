# Reconcile 0.13 around the minimal loop

Date: 2026-10-14

Status: Accepted

## Context

PR #52 merged 0.13 into release/0.12.5 rather than main. Subsequent provider
hardening and loop controls were developed against main's 0.12.5 code.

## Decision

Retain 0.13's separation: Alloy owns the loop, provider protocol and supervised
tool execution. Applications or optional runtimes own long-lived agents,
queues and subscriptions. A future durable runtime owns persistence, replay,
recovery and side-effect retry policy; process supervision alone is not durability.

Memory runs as an ordinary tool. Default compaction is middleware appended
after caller middleware, so it budgets prepared messages, tools and model
limits. Explicit compactor placement is respected. No second execution API
or durable scheduling service is introduced.

Port the provider fixes and composable controls to these boundaries. Remove
the snapshot compatibility harness now that the real 0.13 loop is tested.
Validate direct runs and application-supervised runs on the reconciled source.
Historical live benchmark results remain evidence for their recorded source
hashes, not measurements of the reconciled release.

## Consequences

0.13 retains its documented breaking removals. Publish only after local gates
and the supported-runtime CI matrix pass. The optional alloy_agent repository
has a separate release lifecycle; its availability is not a core dependency.
