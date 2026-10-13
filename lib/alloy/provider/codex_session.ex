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

  defp valid_id?(id) when is_binary(id),
    do: id != "" and not String.starts_with?(id, "-")

  defp valid_id?(_id), do: false

  defp fingerprint(value),
    do:
      Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic])),
        case: :lower
      )
end
