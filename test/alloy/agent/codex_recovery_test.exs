defmodule Alloy.Agent.CodexRecoveryTest do
  use ExUnit.Case, async: true

  alias Alloy.Provider.Codex

  test "an application-owned supervisor runs the loop and recovers with history intact" do
    parent = self()

    runner =
      fn _executable, args, _opts ->
        path = Enum.at(args, Enum.find_index(args, &(&1 == "--output-last-message")) + 1)
        send(parent, {:host_invocation, args})

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

    supervisor = start_supervised!(Task.Supervisor)

    run = fn prompt, config, messages ->
      supervisor
      |> Task.Supervisor.async_nolink(fn ->
        Alloy.run(prompt,
          provider: {Codex, config},
          messages: messages,
          max_retries: 1,
          retry_backoff_ms: 1
        )
      end)
      |> Task.await()
    end

    assert {:ok, first} = run.("original", config, [])
    assert_receive {:host_invocation, _args}
    continuation = Map.put(config, :provider_state, first.metadata.provider_state)
    assert {:error, failed} = run.("lost-thread-request", continuation, first.messages)
    assert_receive {:host_invocation, ["exec", "resume" | _rest]}
    refute_received {:host_invocation, _args}

    recovered_config = Map.put(continuation, :session_generation, "recovery-1")
    assert {:ok, final} = run.("continue", recovered_config, failed.messages)
    assert final.error == nil
    assert final.turns == 1
    assert_receive {:host_invocation, args}
    refute "resume" in args
    assert List.last(args) =~ "original"
    assert List.last(args) =~ "lost-thread-request"
    assert List.last(args) =~ "continue"
  end
end
