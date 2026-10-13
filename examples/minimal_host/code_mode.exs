defmodule MinimalHost.CodeMode do
  @moduledoc """
  Host-owned nested execution experiment for trusted programs.

  This is not a sandbox and never evaluates model-supplied Elixir. A host may
  connect a separately sandboxed interpreter to the dispatch capability. All
  child calls pass through Alloy's existing middleware and tool executor.
  """

  alias Alloy.Agent.State
  alias Alloy.{Message, Middleware}
  alias Alloy.Tool.Executor

  @spec run((function() -> term()), State.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(program, %State{} = state, opts) when is_function(program, 1) do
    timeout = Keyword.fetch!(opts, :timeout)
    max_calls = Keyword.fetch!(opts, :max_calls)
    parent = Keyword.fetch!(opts, :parent_call_id)

    if not (is_integer(timeout) and timeout > 0 and is_integer(max_calls) and max_calls > 0 and
              is_binary(parent)) do
      raise ArgumentError, "positive timeout/max_calls and a parent_call_id are required"
    end

    task = Task.async(fn -> run_program(program, state, opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _stopped -> {:error, :timeout}
    end
  end

  defp run_program(program, state, opts) do
    key = make_ref()
    owner = self()
    script_name = Keyword.get(opts, :script_tool_name, "run_script")
    state = %{state | tool_fns: Map.delete(state.tool_fns, script_name)}
    Process.put(key, {state, 0})

    try do
      dispatch = fn calls ->
        if self() != owner,
          do: raise(ArgumentError, "dispatch must run in the interpreter process")

        dispatch(calls, key, opts)
      end

      {:ok, program.(dispatch)}
    catch
      kind, reason -> {:error, {kind, reason}}
    after
      Process.delete(key)
    end
  end

  defp dispatch(calls, key, opts) when is_list(calls) do
    {state, used} = Process.get(key)
    total = used + length(calls)
    if total > Keyword.fetch!(opts, :max_calls), do: throw(:call_limit)
    parent = Keyword.fetch!(opts, :parent_call_id)

    calls =
      Enum.with_index(calls, used + 1)
      |> Enum.map(fn {call, index} ->
        %{
          id: "#{parent}-#{index}",
          name: Map.fetch!(call, :name),
          input: Map.fetch!(call, :input)
        }
      end)

    Process.put(key, {state, total})

    requested =
      State.append_messages(
        state,
        Message.assistant_blocks(Enum.map(calls, &Map.put(&1, :type, "tool_use")))
      )

    notify = Keyword.get(opts, :on_event, fn _event -> :ok end)
    on_event = fn {type, event} -> notify.({type, Map.put(event, :parent_call_id, parent)}) end

    with %State{} = ready <- Middleware.run(:after_tool_request, requested),
         {:ok, results, metadata} <-
           Executor.execute_all(calls, ready.tool_fns, ready, on_event: on_event),
         %State{} = finished <-
           ready
           |> State.append_messages(results)
           |> State.append_tool_calls(metadata)
           |> then(&Middleware.run(:after_tool_execution, &1)) do
      Process.put(key, {finished, total})
      %{results: results.content, metadata: metadata}
    else
      {:halted, reason} -> throw({:halted, reason})
    end
  end
end
