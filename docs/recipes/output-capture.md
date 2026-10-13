# Producer-side output capture

`examples/minimal_host/output_capture.exs` demonstrates optional host-owned
capture **before** the producing tool discards output. It is not executor
middleware: spilling the built-in bash tool's result cannot recover the middle
that its bounded collector has already removed.

```elixir
MinimalHost.OutputCapture.capture(producer_chunks, private_job_directory,
  max_bytes: 10_000_000,
  preview_bytes: 4_000
)
```

`producer_chunks` is a lazy stream from a host-owned producer. The collector
writes synchronously before requesting the next chunk, stops at the byte
ceiling, and returns a bounded display preview plus the file path and original
byte count. The complete artifact retains original bytes, including invalid
UTF-8; display previews replace invalid sequences.

Each artifact uses an unpredictable name and exclusive creation, with mode
`0600` in an existing private directory. The directory must be owned and
controlled by the host, including its parent path. Public or symlinked final
directories are rejected. Repeated calls never reuse an advertised filename.
Quota violations and ordinary producer failures remove partial output.

## Host obligations

- Own tenant/job isolation, aggregate disk quotas, retention and retrieval.
- Bound upstream chunk sizes and queues; a bounded preview alone is not a
  total-memory guarantee.
- Keep subprocess supervision, deadlines, environment policy and cancellation
  in the producer. This collector does not launch or sandbox shell commands.
- Treat unreferenced artifacts after abrupt process termination as incomplete
  and garbage-collect them. Do not infer completion from file existence.
- Return an authorized retrieval handle to the model, not a cross-tenant or
  unrestricted filesystem path. Keep artifact data out of logs by default.

For bash integration, supply an application-owned `:bash_executor` that
streams from its isolated runner into this collector before producing its
bounded tool result. Do not replace Alloy's safe default collector or assume
`System.cmd/3` alone supplies process-group cancellation.

Tests exercise middle-of-output preservation, bounded previews, unique private
files, lazy producer stopping, failure cleanup, and directory restrictions:

```sh
mix test test/examples/minimal_host_test.exs
```
