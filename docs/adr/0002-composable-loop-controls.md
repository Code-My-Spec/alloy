# Composable loop controls

Date: 2026-10-13

Status: Accepted

## Context

Pi 1.x and other agent loops expose request preparation, tool validation,
and successful completion controls. Alloy needs these ordinary loop capabilities
without taking on the persistence and scheduling of a durable runtime.

## Decision

- Tool argument edits continue through later middleware. Block and halt remain
  terminal. A per-call result hook may replace content and structured data before
  publication, but cannot turn an execution failure into success.
- Keep required-key validation as the default. Opt-in schema validation uses the
  optional `ex_json_schema` adapter (drafts 4/6/7), without coercion or remote
  schema fetching. Invalid schemas are configuration errors. Resolved schemas
  are cached in agent state after the first tool batch and reused only when
  their exact input schemas match. Each refresh retains only current tools;
  disabled validation clears the cache. No global cache, persistence or service
  is introduced. The cache is excluded from results and session metadata.
- `stop_after_tool` completes successfully after a selected successful tool,
  once the entire round settles. The first matching success in source order is
  the final output. Existing `until_tool` requirements still apply.
- `State.prepare/2` updates request inputs through existing `:before_completion`
  middleware, rebuilding tools and deriving model limits together. Explicit
  provider changes clear incompatible opaque provider state conservatively.
  Default compaction middleware is appended after caller middleware so it
  budgets prepared inputs. Explicit compactor placement remains respected.
- Transcript validation and missing-result repair are explicit utilities.
  Repair never executes tools and refuses ambiguous/orphaned results.
- `tool_concurrency` caps parallel execution per run, retaining the existing
  scheduler-count default and sequential tool barriers.

## Consequences

Argument-edit composition is an intentional behaviour change and must be called
out in release notes. Existing tuple tool results, ordinary completion, and
validation defaults remain supported. Schema validation adds no mandatory
runtime dependency. No new public step scheduler or single-tool execution API
is extracted. Durable recovery and multi-agent coordination remain outside core.

## References

- [Minimal core](0001-minimal-core-and-optional-capabilities.md)
- [Pi agent loop](https://github.com/earendil-works/pi/blob/a3a2ee8ec2cbdd41ce8994c570cc6707116d077a/packages/agent/src/agent-loop.ts)
- [AI SDK loop control](https://ai-sdk.dev/docs/agents/loop-control)
