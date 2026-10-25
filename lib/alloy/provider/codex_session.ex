defmodule Alloy.Provider.CodexSession do
  @moduledoc false

  @type plan :: {:fresh, atom()} | {:resume, String.t(), non_neg_integer()}

  @spec plan(map() | nil, [map()], term()) :: plan()
  def plan(state, messages, scope) when is_map(state) do
    session = Map.get(state, "codex_session")
    session_plan(session, messages, scope)
  end

  def plan(_state, _messages, _scope), do: {:fresh, :no_session}

  defp session_plan(nil, _messages, _scope), do: {:fresh, :no_session}

  defp session_plan(state, messages, scope) do
    with %{"id" => id, "count" => count, "hash" => hash, "scope" => saved_scope} <- state,
         true <- valid_id?(id),
         true <- is_integer(count) and count > 0 and count < length(messages),
         true <- saved_scope == fingerprint(scope),
         true <- hash == fingerprint(Enum.take(messages, count)) do
      {:resume, id, count}
    else
      _ -> {:fresh, :history_or_config_changed}
    end
  end

  @spec remember([map()], term(), String.t() | nil) :: map()
  def remember(messages, scope, id) do
    if valid_id?(id) do
      %{
        "codex_session" => %{
          "id" => id,
          "count" => length(messages),
          "hash" => fingerprint(messages),
          "scope" => fingerprint(scope)
        }
      }
    else
      %{"codex_session" => nil}
    end
  end

  @doc """
  Record the thread's size after a turn, and whether Codex compacted it: a
  thread that shrank below half its last size was summarised, and the next
  resumed turn sends the system prompt and tools again.
  """
  @spec note_thread_size(map(), non_neg_integer() | nil, plan(), map() | nil) :: map()
  def note_thread_size(%{"codex_session" => %{} = session} = state, size, plan, previous_state)
      when is_integer(size) do
    previous = previous_size(plan, previous_state)
    compacted? = is_integer(previous) and size < div(previous, 2)

    %{state | "codex_session" => Map.merge(session, %{"size" => size, "resend" => compacted?})}
  end

  def note_thread_size(state, _size, _plan, _previous_state), do: state

  @doc """
  Count a new thread started partway through a conversation: the whole
  transcript went out uncached. A first turn (nothing before it) is not one.
  Carried across turns, so a caller can tell from two states whether a turn
  started one, and why (`fresh_threads/1`).
  """
  @spec note_fresh(map(), plan(), [map()], map() | nil) :: map()
  def note_fresh(state, {:fresh, reason}, messages, previous_state)
      when reason != :ephemeral and length(messages) > 1 do
    {count, _reason} = fresh_threads(previous_state)
    Map.put(state, "fresh_threads", %{"count" => count + 1, "reason" => to_string(reason)})
  end

  def note_fresh(state, _plan, _messages, previous_state) do
    case previous_state do
      %{"fresh_threads" => fresh} -> Map.put(state, "fresh_threads", fresh)
      _ -> state
    end
  end

  @doc "How many mid-conversation threads this session has started, and the last one's reason."
  @spec fresh_threads(map() | nil) :: {non_neg_integer(), String.t() | nil}
  def fresh_threads(%{"fresh_threads" => %{"count" => count, "reason" => reason}}),
    do: {count, reason}

  def fresh_threads(_state), do: {0, nil}

  @doc "Whether the next resumed turn should carry the system prompt and tools again."
  @spec resend_static?(map() | nil) :: boolean()
  def resend_static?(%{"codex_session" => %{"resend" => true}}), do: true
  def resend_static?(_state), do: false

  # Carried across turns in the session map the caller hands back.
  defp previous_size({:resume, _id, _count}, %{"codex_session" => %{"size" => size}}), do: size
  defp previous_size(_plan, _previous_state), do: nil

  defp valid_id?(id) when is_binary(id),
    do: id != "" and not String.starts_with?(id, "-")

  defp valid_id?(_id), do: false

  defp fingerprint(value),
    do:
      Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic])),
        case: :lower
      )
end
