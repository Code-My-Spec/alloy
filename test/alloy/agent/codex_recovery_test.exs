defmodule Alloy.Agent.CodexRecoveryTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.Server
  alias Alloy.Provider.Codex

  test "a server recovers a missing thread using a new generation with history intact" do
    parent = self()

    runner =
      fn _executable, args, _opts ->
        path = Enum.at(args, Enum.find_index(args, &(&1 == "--output-last-message")) + 1)
        send(parent, {:server_invocation, args})

        if Enum.take(args, 2) == ["exec", "resume"] do
          {~s({"type":"error","message":"thread not found"}\n), 1}
        else
          File.write!(path, ~s({"stop_reason":"end_turn","text":"reply","tool_calls":[]}))
          {~s({"type":"thread.started","thread_id":"thread-1"}\n), 0}
        end
      end

    config = %{
      model: "test-model",
      persist_session: true,
      workdir: System.tmp_dir!(),
      command_runner: runner
    }

    server =
      start_supervised!({Server, provider: {Codex, config}, max_retries: 1, retry_backoff_ms: 1})

    assert {:ok, _result} = Server.chat(server, "original")
    assert_receive {:server_invocation, _args}
    assert {:error, _result} = Server.chat(server, "lost-thread-request")
    assert_receive {:server_invocation, ["exec", "resume" | _rest]}
    refute_received {:server_invocation, _args}
    history = Server.messages(server)

    assert :ok =
             Server.set_model(server,
               provider: {Codex, Map.put(config, :session_generation, "recovery-1")}
             )

    assert Server.messages(server) == history
    assert {:ok, _result} = Server.chat(server, "continue")
    assert_receive {:server_invocation, args}
    refute "resume" in args
    assert List.last(args) =~ "original"
    assert List.last(args) =~ "lost-thread-request"
    assert List.last(args) =~ "continue"
  end
end
