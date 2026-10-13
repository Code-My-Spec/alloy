defmodule Alloy.Provider.CodexSessionTest do
  use ExUnit.Case, async: true

  alias Alloy.Provider.CodexSession

  test "continuation state survives JSON persistence" do
    messages = [%{"role" => "user", "content" => "hello"}]
    scope = %{home: "private-home"}

    saved =
      CodexSession.remember(messages, scope, "thread-1") |> Jason.encode!() |> Jason.decode!()

    assert {:resume, "thread-1", 1} = CodexSession.plan(saved, messages ++ messages, scope)
    assert {:fresh, :no_session} = CodexSession.plan(nil, messages, scope)
  end

  test "validates saved state and resets on unchanged or shortened history" do
    messages = [%{role: "user", content: "hello"}]
    scope = %{home: "private-home"}
    saved = CodexSession.remember(messages, scope, "thread-1")
    assert {:resume, "thread-1", 1} = CodexSession.plan(saved, messages ++ messages, scope)

    for state <- [
          nil,
          %{},
          %{"codex_session" => nil},
          put_in(saved, ["codex_session", "count"], -1),
          put_in(saved, ["codex_session", "id"], "--last")
        ] do
      assert {:fresh, _reason} = CodexSession.plan(state, messages ++ messages, scope)
    end

    assert {:fresh, _reason} = CodexSession.plan(saved, messages, scope)
    assert {:fresh, _reason} = CodexSession.plan(saved, [], scope)
    assert CodexSession.remember(messages, scope, nil) == %{"codex_session" => nil}
    assert CodexSession.remember(messages, scope, "") == %{"codex_session" => nil}
  end
end
