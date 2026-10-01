defmodule Alloy.Provider.Codex do
  @moduledoc """
  Provider for ChatGPT-plan-backed Codex execution via `codex exec`.

  This provider treats Codex as a structured completion backend rather than a
  full agent runtime. Alloy remains responsible for the tool loop, while Codex
  receives the current transcript and available tool definitions, then returns
  JSON describing either a final assistant response or one or more tool calls.

  ## Config

  Required:
  - `:model` - Codex model name (for example `"gpt-5.4"`)

  Optional:
  - `:codex_bin` - Executable path (default: `"codex"`)
  - `:workdir` - Directory passed to `codex exec` (defaults to a temp dir)
  - `:profile` - Optional Codex config profile
  - `:codex_home` - Override `CODEX_HOME` instead of using the isolated home
  - `:auth_path` - Override source `auth.json` copied into the isolated home
    (default: `~/.codex/auth.json`)
  - `:tmp_dir` - Parent for the provider's temp working directory and the
    isolated home (default: `System.tmp_dir!/0`)
  - `:timeout_ms` - Timeout for a single `codex exec` invocation
    (default: `120_000`)
  - `:receive_timeout` - Optional turn deadline timeout injected by Alloy's
    retry loop; when present it caps `:timeout_ms`
  - `:command_runner` - Test hook matching `System.cmd/3`
  - `:system_prompt` - System prompt string

  ## Session continuation (`exec resume`)

  Codex keeps its own conversation history, so only the first turn sends the
  whole transcript. Every later turn resumes the thread with `codex exec resume
  <thread_id>` and sends just the messages Codex has not seen, which is what
  lets the prefix come back as `cached_input_tokens`. Measured on codex-cli
  0.157.1: a resumed second turn recalled the first and read 20,864 of 47,350
  input tokens from cache.

  Resumption uses `Alloy.Provider.CliSession`, the same `:provider_state`
  prefix-hash check as `Alloy.Provider.ClaudeCode`: a transcript rewritten by
  compaction goes out fresh with the full history. If a resumed run finishes
  without producing a response (the thread is gone because the home was
  cleared), the turn is retried fresh. `exec resume` has no `--profile`, so a
  `:profile` applies to the turn that started the thread and not to resumed
  ones.

  ## Notes

  - Authentication is handled by the local `codex` CLI login state.
  - By default the provider uses an isolated `CODEX_HOME` holding only
    `auth.json` (plus `config.toml` when a `:profile` is set), which avoids
    pulling in the user's full MCP/plugin config. It lives at
    `<tmp_dir>/alloy-codex-home` and persists across calls, because that is
    where Codex records the threads it resumes.
  - Usage comes from the `turn.completed` event of `--json` output. Codex's
    `input_tokens` includes the cached part; it is reported here as Alloy
    counts it, with `input_tokens` the uncached remainder and
    `cache_read_input_tokens` the cached part.
  - Streaming is emulated by running a normal completion and replaying the final
    text to the provided callback.
  """

  @behaviour Alloy.Provider

  require Logger

  alias Alloy.Message
  alias Alloy.Provider.CliSession

  @default_timeout_ms 120_000
  @default_codex_bin "codex"
  @output_truncation 4_000
  @error_truncation 2_000
  @zero_usage %{input_tokens: 0, output_tokens: 0}

  # Matches any `\X` where X is NOT a valid JSON single-character escape
  # (valid set: " \ / b f n r t u). Used by the decode repair pass.
  @invalid_json_escape_re ~r{\\(?!["\\/bfnrtu])}

  @response_schema %{
    type: "object",
    additionalProperties: false,
    properties: %{
      stop_reason: %{type: "string", enum: ["end_turn", "tool_use"]},
      text: %{type: "string"},
      tool_calls: %{
        type: "array",
        items: %{
          type: "object",
          additionalProperties: false,
          properties: %{
            call_id: %{type: "string"},
            name: %{type: "string"},
            arguments_json: %{type: "string"}
          },
          required: ["call_id", "name", "arguments_json"]
        }
      }
    },
    required: ["stop_reason", "text", "tool_calls"]
  }

  # Pre-encoded at compile time — the schema is static, no need to
  # re-encode it on every `complete/3` call.
  @response_schema_json Jason.encode!(@response_schema)

  @typedoc """
  Configuration for the Codex provider. See the module doc for field semantics.
  """
  @type config :: %{
          required(:model) => String.t(),
          optional(:codex_bin) => String.t(),
          optional(:workdir) => String.t(),
          optional(:profile) => String.t(),
          optional(:codex_home) => String.t(),
          optional(:auth_path) => String.t(),
          optional(:tmp_dir) => String.t(),
          optional(:timeout_ms) => pos_integer(),
          optional(:receive_timeout) => pos_integer(),
          optional(:system_prompt) => String.t(),
          optional(:command_runner) => (String.t(), [String.t()], keyword() ->
                                          {String.t(), integer()}),
          optional(:provider_state) => map()
        }

  @impl true
  @spec complete([Message.t()], [Alloy.Provider.tool_def()], config()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    case prepare_paths(config) do
      {:ok, paths} ->
        try do
          with :ok <- File.write(paths.schema_path, @response_schema_json) do
            config
            |> CliSession.plan(messages)
            |> run_turn(messages, tool_defs, paths, config)
          end
        after
          cleanup_paths(paths)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_turn(plan, messages, tool_defs, paths, config) do
    prompt = build_turn_prompt(plan, messages, tool_defs, config)

    with :ok <- File.write(paths.prompt_path, prompt),
         {:ok, command_result} <- run_codex(prompt, paths, config, plan),
         {:ok, payload} <- read_turn_payload(plan, paths.last_message_path, command_result) do
      parse_payload(payload, config, command_result, messages)
    else
      {:resume_failed, session_id, reason} ->
        Logger.warning(
          "Alloy.Provider.Codex could not resume thread #{session_id}, " <>
            "sending the full transcript instead: #{reason}"
        )

        _ = File.rm(paths.last_message_path)
        run_turn(:fresh, messages, tool_defs, paths, config)

      {:error, _reason} = error ->
        error
    end
  end

  # A resumed run that finished without a response most likely named a thread
  # this home no longer has. Only a *finished* run: a timeout is `{:error, _}`
  # from `run_codex/4` and is not retried, since a second full-length attempt
  # would double the wait for the same outcome.
  defp read_turn_payload({:resume, session_id, _new}, path, command_result) do
    case read_payload_or_error(path, command_result) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:resume_failed, session_id, reason}
    end
  end

  defp read_turn_payload(:fresh, path, command_result),
    do: read_payload_or_error(path, command_result)

  defp build_turn_prompt({:resume, _session_id, new_messages}, _messages, tool_defs, _config),
    do: build_incremental_prompt(new_messages, tool_defs)

  defp build_turn_prompt(:fresh, messages, tool_defs, config),
    do: build_prompt(messages, tool_defs, config)

  @impl true
  @spec stream([Message.t()], [Alloy.Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    with {:ok, result} <- complete(messages, tool_defs, config),
         :ok <- emit_chunks(result, on_chunk) do
      {:ok, result}
    end
  end

  defp prepare_paths(config) do
    base_dir = build_base_dir(config)

    with :ok <- mkdir_base(base_dir),
         {:ok, codex_home} <- prepare_codex_home(base_dir, config) do
      {:ok, build_paths(base_dir, codex_home, config)}
    else
      {:error, reason} ->
        # `File.rm_rf/1` is a no-op if the directory was never created,
        # so this is safe to run on both mkdir and prepare_codex_home failures.
        _ = File.rm_rf(base_dir)
        {:error, reason}
    end
  end

  defp build_base_dir(config) do
    parent = Map.get(config, :tmp_dir) || System.tmp_dir!()
    Path.join(parent, "alloy-codex-#{System.unique_integer([:positive])}")
  end

  defp mkdir_base(base_dir) do
    case File.mkdir_p(base_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to prepare Codex temp directory: #{inspect(reason)}"}
    end
  end

  defp build_paths(base_dir, codex_home, config) do
    %{
      base_dir: base_dir,
      codex_home: codex_home,
      prompt_path: Path.join(base_dir, "prompt.txt"),
      schema_path: Path.join(base_dir, "response_schema.json"),
      last_message_path: Path.join(base_dir, "last_message.json"),
      workdir: Map.get(config, :workdir, base_dir)
    }
  end

  defp cleanup_paths(%{base_dir: base_dir}) do
    _ = File.rm_rf(base_dir)
    :ok
  end

  defp prepare_codex_home(_base_dir, %{command_runner: _runner}) do
    {:ok, nil}
  end

  defp prepare_codex_home(_base_dir, %{codex_home: codex_home}) when is_binary(codex_home) do
    {:ok, codex_home}
  end

  # Outside `base_dir` and never cleaned up: Codex records its threads under
  # `CODEX_HOME/sessions`, and a home deleted after every call left nothing for
  # the next turn to resume.
  #
  # A profile needs the user's `config.toml`, and a shared home that once held
  # it would hand it — MCP servers and all — to every unprofiled call after, so
  # the two get separate homes.
  defp prepare_codex_home(_base_dir, config) do
    parent = Map.get(config, :tmp_dir) || System.tmp_dir!()
    codex_home = Path.join(parent, codex_home_name(config))
    auth_source = Map.get(config, :auth_path, default_auth_path())

    with :ok <- File.mkdir_p(codex_home),
         :ok <- copy_file(auth_source, Path.join(codex_home, "auth.json")) do
      maybe_copy_config(codex_home, config)
    end
  end

  defp codex_home_name(%{profile: profile}) when is_binary(profile) and profile != "",
    do: "alloy-codex-home-with-config"

  defp codex_home_name(_config), do: "alloy-codex-home"

  defp run_codex(prompt, paths, config, plan) do
    executable = Map.get(config, :codex_bin, @default_codex_bin)
    timeout = effective_timeout(config)

    args =
      plan
      |> exec_args()
      |> Kernel.++([
        "--json",
        "--output-schema",
        paths.schema_path,
        "--output-last-message",
        paths.last_message_path
      ])
      |> maybe_append_profile(config)
      |> maybe_append_model(config)
      |> maybe_append_session(plan)
      |> append_prompt_arg(prompt, config)

    if injected_runner?(config) do
      run_injected(config, executable, args, paths)
    else
      run_port(executable, args, paths, timeout)
    end
  end

  defp effective_timeout(config) do
    timeout_ms = Map.get(config, :timeout_ms, @default_timeout_ms)

    case Map.get(config, :receive_timeout) do
      receive_timeout when is_integer(receive_timeout) and receive_timeout > 0 ->
        min(receive_timeout, timeout_ms)

      _ ->
        timeout_ms
    end
  end

  # Test path: the caller supplies a synchronous function matching
  # `System.cmd/3`. No timeout enforcement — tests should be fast enough
  # to rely on ExUnit's own timeout.
  defp run_injected(config, executable, args, paths) do
    runner = Map.fetch!(config, :command_runner)
    opts = [cd: paths.workdir, stderr_to_stdout: true]

    case runner.(executable, args, opts) do
      {output, status} when is_binary(output) and is_integer(status) ->
        {:ok, %{output: output, status: status}}

      other ->
        {:error, "codex exec returned unexpected result: #{inspect(other)}"}
    end
  rescue
    error in ErlangError ->
      {:error, "codex exec failed to start: #{Exception.message(error)}"}
  end

  # Real path: spawn via Port so we capture the OS pid and can kill the
  # subprocess on timeout. `exec env ... codex ...` makes the shell process
  # replace itself with env, which replaces itself with codex — so
  # `Port.info(:os_pid)` returns codex's own pid rather than a shell pid
  # whose children we'd otherwise orphan.
  defp run_port(executable, args, paths, timeout) do
    shell_command = build_port_command(executable, args, paths)

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          {:args, ["-lc", shell_command]},
          {:cd, paths.workdir},
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout
        ]
      )

    # Port.info/2 returns nil when the process already exited — its output
    # and exit_status messages are still in the mailbox, so collect them;
    # there is just no OS pid left to kill on timeout.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> collect_port(port, os_pid, timeout, [])
      nil -> collect_port(port, nil, timeout, [])
    end
  rescue
    error in ErlangError ->
      {:error, "codex exec failed to start: #{Exception.message(error)}"}
  end

  defp build_port_command(executable, args, paths) do
    env_args =
      [{"OTEL_SDK_DISABLED", "true"}, {"CODEX_HOME", paths.codex_home}]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(" ", fn {key, value} -> shell_escape("#{key}=#{value}") end)

    "exec env " <>
      env_args <>
      " " <>
      Enum.map_join([executable | args], " ", &shell_escape/1) <>
      " < " <>
      shell_escape(paths.prompt_path)
  end

  defp collect_port(port, os_pid, timeout, acc) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        collect_port(port, os_pid, timeout, [acc, data])

      {^port, {:exit_status, status}} ->
        {:ok, %{output: IO.iodata_to_binary(acc), status: status}}
    after
      timeout ->
        _ = kill_os_process(os_pid)
        _ = close_and_drain(port)
        {:error, "codex exec timed out after #{timeout}ms"}
    end
  end

  # SIGTERM with a 100ms grace window, then SIGKILL. Best-effort — if
  # codex has already exited, the second kill is a no-op.
  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) do
    _ = System.cmd("/bin/kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    Process.sleep(100)
    _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  defp close_and_drain(port) do
    _ =
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

    drain_port_messages(port)
  end

  defp drain_port_messages(port) do
    receive do
      {^port, _} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end

  defp append_prompt_arg(args, prompt, config) do
    if injected_runner?(config) do
      args ++ [prompt]
    else
      args ++ ["-"]
    end
  end

  # An explicit `:command_runner` in config means the caller is driving
  # process execution themselves (almost always a test). Real usage goes
  # through the shell wrapper so we can inject env and stdin-feed the prompt.
  defp injected_runner?(config), do: Map.has_key?(config, :command_runner)

  defp codex_error(status, output) do
    message =
      output
      |> String.trim()
      |> truncate(@error_truncation)

    "codex exec failed with status #{status}: #{message}"
  end

  defp read_payload_or_error(path, %{status: status, output: output}) do
    case read_payload(path) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} when status == 0 ->
        {:error, reason}

      {:error, _reason} ->
        {:error, codex_error(status, output)}
    end
  end

  defp read_payload(path) do
    with {:ok, content} <- File.read(path),
         {:ok, payload} <- Jason.decode(content) do
      {:ok, payload}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "failed to read Codex response file: #{inspect(reason)}"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "failed to decode Codex response JSON: #{Exception.message(error)}"}
    end
  end

  defp parse_payload(
         %{"stop_reason" => "end_turn", "text" => text, "tool_calls" => tool_calls},
         config,
         command_result,
         messages
       )
       when is_binary(text) and is_list(tool_calls) do
    if tool_calls == [] do
      {:ok, completion(:end_turn, Message.assistant(text), config, command_result, messages)}
    else
      {:error, "Codex returned tool_calls for an end_turn response"}
    end
  end

  # See `Alloy.Provider.ClaudeCode` for why a tool_use with no tool calls ends
  # the turn on its text, or is retried when it has none.
  defp parse_payload(
         %{"stop_reason" => "tool_use", "text" => text, "tool_calls" => []} = payload,
         config,
         command_result,
         messages
       )
       when is_binary(text) do
    if String.trim(text) == "" do
      {:error, "malformed_reply: Codex returned tool_use without any tool calls"}
    else
      parse_payload(%{payload | "stop_reason" => "end_turn"}, config, command_result, messages)
    end
  end

  defp parse_payload(
         %{"stop_reason" => "tool_use", "text" => text, "tool_calls" => tool_calls},
         config,
         command_result,
         messages
       )
       when is_binary(text) and is_list(tool_calls) do
    with {:ok, blocks} <- parse_tool_blocks(text, tool_calls) do
      reply = Message.assistant_blocks(blocks)
      {:ok, completion(:tool_use, reply, config, command_result, messages)}
    end
  end

  defp parse_payload(payload, _config, _command_result, _messages) do
    {:error, "unexpected Codex response payload: #{inspect(payload)}"}
  end

  defp completion(stop_reason, reply, config, command_result, messages) do
    events = json_events(command_result.output)

    %{
      stop_reason: stop_reason,
      messages: [reply],
      usage: extract_usage(events),
      response_metadata: response_metadata(config, command_result),
      provider_state: CliSession.next_state(messages, reply, thread_id(events))
    }
  end

  # `--json` writes one event per line; stderr is merged into the same stream,
  # so anything that does not decode to an event is skipped.
  defp json_events(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => type} = event} when is_binary(type) -> [event]
        _ -> []
      end
    end)
  end

  defp thread_id(events) do
    Enum.find_value(events, fn
      %{"type" => "thread.started", "thread_id" => id} when is_binary(id) -> id
      _ -> nil
    end)
  end

  # Codex counts cached tokens inside `input_tokens`; `Alloy.Usage` prices
  # `input_tokens` at the full rate, so the cached part is split out.
  defp extract_usage(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(@zero_usage, fn
      %{
        "type" => "turn.completed",
        "usage" => %{"input_tokens" => input, "output_tokens" => output} = usage
      }
      when is_integer(input) and is_integer(output) ->
        cached = count(usage, "cached_input_tokens")

        %{
          input_tokens: max(input - cached, 0),
          output_tokens: output,
          cache_read_input_tokens: cached,
          cache_creation_input_tokens: count(usage, "cache_write_input_tokens")
        }

      _ ->
        nil
    end)
  end

  defp count(usage, key) do
    case Map.get(usage, key) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp parse_tool_blocks(text, tool_calls) do
    tool_calls
    |> Enum.with_index(1)
    |> Enum.reduce_while([], fn {tool_call, index}, acc ->
      case build_tool_block(tool_call, index) do
        {:ok, block} -> {:cont, [block | acc]}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:error, _} = err -> err
      blocks -> finalize_tool_blocks(text, Enum.reverse(blocks))
    end
  end

  defp build_tool_block(tool_call, index) do
    with {:ok, call_id} <- tool_call_id(tool_call, index),
         {:ok, name} <- fetch_string(tool_call, "name"),
         {:ok, arguments} <- fetch_arguments(tool_call) do
      {:ok, %{type: "tool_use", id: call_id, name: name, input: arguments}}
    end
  end

  defp finalize_tool_blocks(text, tool_blocks) do
    case String.trim(text) do
      "" -> {:ok, tool_blocks}
      trimmed -> {:ok, [%{type: "text", text: trimmed} | tool_blocks]}
    end
  end

  defp tool_call_id(tool_call, index) do
    case Map.get(tool_call, "call_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:ok, "call_#{index}"}
      other -> {:error, "invalid Codex tool call id: #{inspect(other)}"}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, "invalid Codex field #{inspect(key)}: #{inspect(other)}"}
    end
  end

  defp fetch_arguments(map) do
    with {:ok, json} <- fetch_string(map, "arguments_json"),
         {:ok, decoded} when is_map(decoded) <- decode_arguments_json(json) do
      {:ok, decoded}
    else
      {:ok, _non_map} -> {:error, "Codex tool call arguments must decode to a JSON object"}
      {:error, _reason} = err -> err
    end
  end

  # Codex occasionally emits strings containing invalid JSON escape sequences
  # — most often `\d`, `\s`, `\p`, `\A` from regex source inside code payloads.
  # Valid single-character JSON escapes after `\` are: " \ / b f n r t u.
  # If the first decode fails, we double any other `\X` and retry.
  #
  # This does NOT help cases where Codex *under-escapes* an otherwise valid
  # sequence (e.g. emits `\n` when the intent was a literal backslash-n):
  # Jason decodes that successfully and silently produces wrong data. Fixing
  # that class of error needs a prompt-level constraint, not a post-hoc patch.
  defp decode_arguments_json(json) do
    case Jason.decode(json) do
      {:ok, _} = ok ->
        ok

      {:error, %Jason.DecodeError{}} ->
        case json |> repair_backslash_escapes() |> Jason.decode() do
          {:ok, _} = ok ->
            ok

          {:error, %Jason.DecodeError{} = error} ->
            {:error, "invalid Codex arguments_json: #{Exception.message(error)}"}
        end
    end
  end

  # Replace bare backslash sequences that are not valid JSON escapes by
  # doubling the backslash, converting `\X` (invalid) into `\\X` (valid —
  # literal backslash followed by X).
  defp repair_backslash_escapes(json) do
    Regex.replace(@invalid_json_escape_re, json, fn match -> "\\" <> match end)
  end

  defp emit_chunks(%{messages: [%Message{content: text}]}, on_chunk) when is_binary(text) do
    on_chunk.(text)
    :ok
  end

  defp emit_chunks(%{messages: [%Message{content: blocks}]}, on_chunk) when is_list(blocks) do
    blocks
    |> Enum.filter(&match?(%{type: "text", text: _}, &1))
    |> Enum.each(fn %{text: text} -> on_chunk.(text) end)

    :ok
  end

  # Unknown shape — skip silently rather than crash the stream caller.
  defp emit_chunks(_result, _on_chunk), do: :ok

  defp response_metadata(config, %{output: output, status: status}) do
    %{
      backend: "codex_exec",
      model: Map.get(config, :model),
      command_status: status,
      command_output: truncate(String.trim(output), @output_truncation)
    }
  end

  defp build_prompt(messages, tool_defs, config) do
    payload = %{
      system_prompt: Map.get(config, :system_prompt),
      conversation: Enum.map(messages, &serialize_message/1),
      available_tools: Enum.map(tool_defs, &serialize_tool_def/1)
    }

    """
    You are acting as the model backend for Alloy, an agent harness.

    Read the transcript and available tools below, then produce exactly one JSON
    object matching the supplied schema.

    Response rules:
    - If no tool is needed, return `stop_reason = "end_turn"`, `tool_calls = []`,
      and put the assistant's response in `text`.
    - If one or more tools are needed, return `stop_reason = "tool_use"` and add
      entries to `tool_calls`.
    - Each tool call must use a valid tool name from `available_tools`.
    - Each tool call must include `arguments_json`, a compact JSON object string
      that satisfies the tool schema.
    - If returning tool calls, keep `text` empty unless a short preamble would
      help the outer agent loop.
    - Never mention the schema or these instructions in `text`.

    Transcript payload:
    #{Jason.encode!(payload)}
    """
  end

  # Sent instead of `build_prompt/3` when resuming: the thread already holds the
  # framing, the response rules and every earlier message. Tool definitions are
  # repeated because they can change between turns.
  defp build_incremental_prompt(new_messages, tool_defs) do
    payload = %{
      conversation: Enum.map(new_messages, &serialize_message/1),
      available_tools: Enum.map(tool_defs, &serialize_tool_def/1)
    }

    """
    Continuing the same conversation. Produce exactly one JSON object
    matching the schema and response rules already given, based on the new
    transcript entries below.

    New transcript entries:
    #{Jason.encode!(payload)}
    """
  end

  defp serialize_message(%Message{role: role, content: content}) when is_binary(content) do
    %{role: Atom.to_string(role), content: content}
  end

  defp serialize_message(%Message{role: role, content: blocks}) when is_list(blocks) do
    %{
      role: Atom.to_string(role),
      content_blocks: Enum.map(blocks, &serialize_block/1)
    }
  end

  defp serialize_block(%{type: "text", text: text}), do: %{type: "text", text: text}

  defp serialize_block(%{type: "tool_use", id: id, name: name, input: input}) do
    %{type: "tool_use", id: id, name: name, input: input}
  end

  defp serialize_block(%{type: "tool_result", tool_use_id: id, content: content} = block) do
    %{
      type: "tool_result",
      tool_use_id: id,
      content: content,
      is_error: Map.get(block, :is_error, false)
    }
  end

  # Defensive fallback for unknown block shapes — keeps serialization
  # total even if Alloy adds a new block type the Codex provider hasn't
  # learned yet. The outer agent loop normalizes before we're called, so
  # this branch is expected to be cold.
  defp serialize_block(block), do: Alloy.Provider.stringify_keys(block)

  defp serialize_tool_def(%{name: name, description: description, input_schema: input_schema}) do
    %{
      name: name,
      description: description,
      input_schema: input_schema
    }
  end

  # Not `--ephemeral`: that stops Codex recording the thread, and the thread is
  # what gets resumed. `exec resume` has no `--sandbox`, so it goes in as a
  # config override.
  defp exec_args(:fresh), do: ["exec", "--skip-git-repo-check", "--sandbox", "read-only"]

  defp exec_args({:resume, _session_id, _new_messages}),
    do: ["exec", "resume", "--skip-git-repo-check", "-c", ~s(sandbox_mode="read-only")]

  # Fresh turns only: `exec resume` has no `--profile` (codex-cli 0.157.1).
  defp maybe_append_profile(["exec", "resume" | _] = args, _config), do: args

  defp maybe_append_profile(args, config) do
    case Map.get(config, :profile) do
      nil -> args
      profile -> args ++ ["--profile", profile]
    end
  end

  # The thread id is positional, ahead of the prompt marker.
  defp maybe_append_session(args, {:resume, session_id, _new_messages}), do: args ++ [session_id]
  defp maybe_append_session(args, :fresh), do: args

  defp maybe_append_model(args, config) do
    case Map.get(config, :model) do
      nil -> args
      model -> args ++ ["--model", model]
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  # Copied then renamed, because the home is shared: a plain `File.cp/2`
  # truncates the destination first, and a `codex` another agent started a
  # moment earlier could read a half-written `auth.json`.
  defp copy_file(source, destination) do
    staging = "#{destination}.#{System.unique_integer([:positive])}"

    with :ok <- File.cp(source, staging),
         :ok <- File.rename(staging, destination) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(staging)
        {:error, "failed to copy #{Path.basename(source)} into Codex home: #{inspect(reason)}"}
    end
  end

  defp maybe_copy_config(codex_home, %{profile: profile})
       when is_binary(profile) and profile != "" do
    config_source = default_config_path()

    case File.exists?(config_source) do
      true ->
        case copy_file(config_source, Path.join(codex_home, "config.toml")) do
          :ok -> {:ok, codex_home}
          {:error, reason} -> {:error, reason}
        end

      false ->
        {:error, "missing ~/.codex/config.toml required for Codex profile #{inspect(profile)}"}
    end
  end

  defp maybe_copy_config(codex_home, _config), do: {:ok, codex_home}

  defp default_auth_path do
    Path.join(System.user_home!(), ".codex/auth.json")
  end

  defp default_config_path do
    Path.join(System.user_home!(), ".codex/config.toml")
  end

  # `limit` is a character budget, not a byte budget — `String.slice/3`
  # respects grapheme boundaries so we never split a multibyte codepoint
  # mid-sequence and produce invalid UTF-8 in user-facing fields like
  # `response_metadata.command_output`.
  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) > limit do
      String.slice(text, 0, limit) <> "..."
    else
      text
    end
  end
end
