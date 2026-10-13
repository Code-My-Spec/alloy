defmodule Alloy.Middleware do
  @moduledoc """
  Behaviour for middleware that wraps the agent loop.

  Middleware runs at defined hook points:
  - `:before_completion` - Prepare request inputs before compaction and the provider call
  - `:after_completion` - Finalize a normal answer or successful `:stop_after_tool` completion
  - `:after_compaction` - After context compaction occurs (only fires when messages changed)
  - `:after_tool_request` - After provider response with :tool_use (gates tool execution)
  - `:after_tool_execution` - After tools have been executed
  - `:before_tool_call` - Compose argument edits and policy checks before execution
  - `:after_tool_call` - Replace each result's content/data before publication
  - `:on_error` - When an error occurs

  Middleware can modify state (e.g., add logging, enforce policies,
  track metrics) but should not change the fundamental loop behavior.
  """

  alias Alloy.Agent.State

  @type hook ::
          :before_completion
          | :after_completion
          | :after_compaction
          | :after_tool_request
          | :after_tool_execution
          | :on_error
          | :before_tool_call
          | :after_tool_call
          | :session_start
          | :session_end

  @type tool_result :: %{content: String.t(), data: map() | nil, is_error: boolean()}
  @type call_result ::
          State.t()
          | {:block, String.t()}
          | {:halt, String.t()}
          | {:edit, map()}
          | {:result, tool_result()}

  @doc """
  Called at the specified hook point. Returns modified state,
  `{:block, reason}` for `:before_tool_call` to prevent execution,
  or `{:halt, reason}` to stop the entire agent loop immediately.
  """
  @callback call(hook(), State.t()) :: call_result()

  @doc """
  Runs all middleware for a given hook point.

  Middleware can return `{:halt, reason}` to stop processing immediately
  and mark the agent as halted. Returns either the final state or
  `{:halted, reason}` tuple.
  """
  @spec run(hook(), State.t()) :: State.t() | {:halted, String.t()}
  def run(hook, %State{} = state) do
    Enum.reduce_while(state.config.middleware, state, fn middleware, acc ->
      case middleware.call(hook, acc) do
        {:halt, reason} ->
          {:halt, {:halted, reason}}

        %State{} = new_state ->
          {:cont, new_state}

        {:block, reason} ->
          raise ArgumentError,
                "#{inspect(middleware)} returned {:block, #{inspect(reason)}} " <>
                  "from hook #{inspect(hook)}, but {:block, reason} is only valid for " <>
                  "the :before_tool_call hook. Use {:halt, reason} to stop the agent loop."
      end
    end)
  end

  @doc """
  Runs `:before_tool_call` middleware for a single tool call.

  Injects the tool call into `state.config.context[:current_tool_call]`
  before running middleware. Returns `:ok`, `{:block, reason}`,
  `{:edit, modified_call}`, or `{:halted, reason}`.

  The `{:edit, modified_call}` return lets middleware rewrite tool arguments
  before execution. The modified call must keep the same `:id` and `:name`.

  Edits pass the modified call to subsequent middleware. Block and halt
  stop the chain. State returned from this hook does not alter loop state.
  """
  @spec run_before_tool_call(State.t(), map()) ::
          :ok | {:block, String.t()} | {:edit, map()} | {:halted, String.t()}
  def run_before_tool_call(%State{} = state, tool_call) do
    result =
      Enum.reduce_while(state.config.middleware, {:edit, tool_call}, fn middleware,
                                                                        {:edit, current} ->
        updated_state = tool_state(state, current)

        case middleware.call(:before_tool_call, updated_state) do
          {:block, reason} ->
            {:halt, {:block, reason}}

          {:halt, reason} ->
            {:halt, {:halted, reason}}

          {:edit, modified_call} ->
            validate_edit!(tool_call, modified_call)
            {:cont, {:edit, modified_call}}

          %State{} ->
            {:cont, {:edit, current}}
        end
      end)

    if result == {:edit, tool_call}, do: :ok, else: result
  end

  @doc """
  Runs `:after_tool_call` before publishing each tool outcome.

  Context contains `:current_tool_call` and `:current_tool_result` with
  `:content`, `:data`, and `:is_error`. Return `{:result, result}` to replace
  content and structured data, or the state unchanged. Replacements compose;
  they must retain `:is_error`. State changes are not applied to the loop.
  Hook failures abort execution rather than publishing an unredacted result.
  """
  @spec run_after_tool_call(State.t(), map(), tool_result()) :: tool_result()
  def run_after_tool_call(state, call, result) do
    Enum.reduce(state.config.middleware, result, fn middleware, current ->
      scoped = tool_state(state, call, current)

      case middleware.call(:after_tool_call, scoped) do
        %State{} -> current
        {:result, replacement} -> validate_result!(current, replacement)
      end
    end)
  end

  defp tool_state(state, call, result \\ nil) do
    context =
      state.config.context
      |> Map.put(:current_tool_call, call)
      |> Map.put(:current_tool_result, result)

    %{state | config: %{state.config | context: context}}
  end

  defp validate_result!(original, %{content: content, data: data, is_error: error} = result)
       when is_binary(content) and (is_map(data) or is_nil(data)) and error == original.is_error,
       do: Map.take(result, [:content, :data, :is_error])

  defp validate_result!(_original, _result) do
    raise ArgumentError,
          "tool result replacement requires string content, map/nil data, and unchanged is_error"
  end

  defp validate_edit!(original, modified) do
    unless Map.get(modified, :id) == Map.get(original, :id) and
             Map.get(modified, :name) == Map.get(original, :name) do
      raise ArgumentError,
            "Middleware :edit must preserve the tool call :id and :name. " <>
              "Original: #{inspect(Map.take(original, [:id, :name]))}, " <>
              "Modified: #{inspect(Map.take(modified, [:id, :name]))}"
    end
  end
end
