defmodule Alloy.Provider.CodexTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.Codex

  describe "complete/3" do
    test "returns an end_turn assistant message from Codex JSON output" do
      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            File.write!(
              output_path,
              ~s({"stop_reason":"end_turn","text":"All done","tool_calls":[]})
            )

            "codex\n{\"stop_reason\":\"end_turn\"}\n"
          end)
      }

      assert {:ok, result} = Codex.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :end_turn
      assert result.messages == [Message.assistant("All done")]
      assert result.usage == %{input_tokens: 0, output_tokens: 0}
      assert result.response_metadata.backend == "codex_exec"
      assert result.response_metadata.model == "gpt-5.4"
      assert result.response_metadata.command_status == 0
    end

    test "a tool_use naming no tool ends the turn on its text, or is retried without one" do
      reply = fn text ->
        %{
          model: "gpt-5.4",
          command_runner:
            fake_runner(fn _args, _opts, output_path ->
              payload = %{stop_reason: "tool_use", text: text, tool_calls: []}
              File.write!(output_path, Jason.encode!(payload))
              "codex\n#{Jason.encode!(payload)}\n"
            end)
        }
      end

      assert {:ok, result} = Codex.complete([Message.user("Hi")], [], reply.("Done."))
      assert result.stop_reason == :end_turn
      assert result.messages == [Message.assistant("Done.")]

      assert {:error, reason} = Codex.complete([Message.user("Hi")], [], reply.(""))
      assert Alloy.Provider.Retry.retryable?(reason)
    end

    test "returns tool_use blocks when Codex requests tools" do
      tool_defs = [
        %{
          name: "search_examples",
          description: "Find similar inbox examples",
          input_schema: %{type: "object", properties: %{query: %{type: "string"}}}
        }
      ]

      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            payload = %{
              stop_reason: "tool_use",
              text: "",
              tool_calls: [
                %{
                  call_id: "call_1",
                  name: "search_examples",
                  arguments_json: ~s({"query":"waiting on vendor","limit":2})
                }
              ]
            }

            File.write!(output_path, Jason.encode!(payload))
            "codex\n#{Jason.encode!(payload)}\n"
          end)
      }

      assert {:ok, result} =
               Codex.complete([Message.user("Help me triage this")], tool_defs, config)

      assert result.stop_reason == :tool_use

      assert result.messages == [
               Message.assistant_blocks([
                 %{
                   type: "tool_use",
                   id: "call_1",
                   name: "search_examples",
                   input: %{"query" => "waiting on vendor", "limit" => 2}
                 }
               ])
             ]
    end

    test "builds a structured prompt that includes system prompt and tool definitions" do
      parent = self()

      config = %{
        model: "gpt-5.4",
        system_prompt: "You are an inbox triage harness.",
        command_runner:
          fake_runner(fn args, _opts, output_path ->
            send(parent, {:codex_args, args})
            File.write!(output_path, ~s({"stop_reason":"end_turn","text":"OK","tool_calls":[]}))
            "codex\n{\"stop_reason\":\"end_turn\"}\n"
          end)
      }

      tool_defs = [
        %{
          name: "search_examples",
          description: "Find similar inbox examples",
          input_schema: %{type: "object", properties: %{query: %{type: "string"}}}
        }
      ]

      messages = [
        Message.user("Need a decision"),
        Message.assistant_blocks([
          %{
            type: "tool_use",
            id: "call_1",
            name: "search_examples",
            input: %{"query" => "urgent"}
          },
          %{type: "text", text: "Checking similar examples."}
        ]),
        Message.tool_results([
          %{type: "tool_result", tool_use_id: "call_1", content: "Found two examples"}
        ])
      ]

      assert {:ok, _result} = Codex.complete(messages, tool_defs, config)

      assert_receive {:codex_args, args}
      prompt = List.last(args)

      assert prompt =~ "You are acting as the model backend for Alloy"
      assert prompt =~ "You are an inbox triage harness."
      assert prompt =~ "\"name\":\"search_examples\""
      assert prompt =~ "\"tool_result\""
      assert prompt =~ "\"Found two examples\""
    end

    test "returns a helpful error when Codex output violates the contract" do
      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            File.write!(
              output_path,
              ~s({"stop_reason":"end_turn","text":"oops","tool_calls":[{"call_id":"call_1","name":"bad","arguments":{}}]})
            )

            "codex\n{\"stop_reason\":\"end_turn\"}\n"
          end)
      }

      assert {:error, reason} = Codex.complete([Message.user("Hi")], [], config)
      assert reason =~ "tool_calls"
    end

    test "returns a helpful error when arguments_json is not valid JSON" do
      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            payload = %{
              stop_reason: "tool_use",
              text: "",
              tool_calls: [
                %{call_id: "call_1", name: "search_examples", arguments_json: "{not json}"}
              ]
            }

            File.write!(output_path, Jason.encode!(payload))
            "codex\n#{Jason.encode!(payload)}\n"
          end)
      }

      assert {:error, reason} = Codex.complete([Message.user("Hi")], [], config)
      assert reason =~ "arguments_json"
    end

    test "accepts a parsed payload even if codex exits non-zero" do
      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            File.write!(
              output_path,
              ~s({"stop_reason":"end_turn","text":"Recovered","tool_calls":[]})
            )

            {"codex noise on stderr", 1}
          end)
      }

      assert {:ok, result} = Codex.complete([Message.user("Hi")], [], config)
      assert result.messages == [Message.assistant("Recovered")]
      assert result.response_metadata.command_status == 1
    end

    test "passes the prompt via stdin for the real shell-backed runner" do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "alloy-codex-provider-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      auth_path = Path.join(temp_dir, "auth.json")
      File.write!(auth_path, "{}")

      script_path = Path.join(temp_dir, "fake-codex.sh")

      File.write!(
        script_path,
        """
        #!/bin/sh
        set -eu

        output=""
        last=""

        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then
            shift
            output="$1"
          else
            last="$1"
          fi

          shift
        done

        if [ "$last" != "-" ]; then
          echo "expected stdin prompt marker" >&2
          exit 41
        fi

        prompt="$(cat)"

        case "$prompt" in
          *"Need a decision"*) ;;
          *)
            echo "missing prompt on stdin" >&2
            exit 42
            ;;
        esac

        printf '%s' '{"stop_reason":"end_turn","text":"stdin ok","tool_calls":[]}' > "$output"
        printf '%s\\n' '{"event":"done"}'
        """
      )

      File.chmod!(script_path, 0o755)

      config = %{
        model: "gpt-5.4",
        codex_bin: script_path,
        auth_path: auth_path
      }

      assert {:ok, result} = Codex.complete([Message.user("Need a decision")], [], config)
      assert result.messages == [Message.assistant("stdin ok")]
    end

    test "collects output even when the process exits before os_pid can be read" do
      # Regression: Port.info(port, :os_pid) returns nil when the spawned
      # process has already exited. The output and exit_status messages are
      # still in the mailbox, so a fast-exiting codex must succeed, not
      # error with "port closed before os_pid was available". The race is
      # timing-dependent; the instant-exit script plus repetition makes it
      # likely under the old code and proves the nil branch under the new.
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "alloy-codex-provider-fastexit-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      auth_path = Path.join(temp_dir, "auth.json")
      File.write!(auth_path, "{}")

      script_path = Path.join(temp_dir, "fast-codex.sh")

      File.write!(
        script_path,
        """
        #!/bin/sh
        output=""

        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then
            shift
            output="$1"
          fi

          shift
        done

        cat > /dev/null
        printf '%s' '{"stop_reason":"end_turn","text":"fast exit","tool_calls":[]}' > "$output"
        printf '%s\\n' '{"event":"done"}'
        """
      )

      File.chmod!(script_path, 0o755)

      config = %{
        model: "gpt-5.4",
        codex_bin: script_path,
        auth_path: auth_path
      }

      for _run <- 1..20 do
        assert {:ok, result} = Codex.complete([Message.user("Hi")], [], config)
        assert result.messages == [Message.assistant("fast exit")]
      end
    end

    test "returns a timeout error instead of hanging when the real shell-backed run exceeds timeout_ms" do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "alloy-codex-provider-timeout-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      auth_path = Path.join(temp_dir, "auth.json")
      File.write!(auth_path, "{}")

      script_path = Path.join(temp_dir, "slow-codex.sh")

      File.write!(script_path, """
      #!/bin/sh
      # Drain stdin so the shell redirect completes, then hang.
      cat > /dev/null
      sleep 30
      """)

      File.chmod!(script_path, 0o755)

      config = %{
        model: "gpt-5.4",
        codex_bin: script_path,
        auth_path: auth_path,
        timeout_ms: 200
      }

      # If the Port-based timeout path is broken, this call hangs for 30s
      # and ExUnit's own timeout would catch it — the assertion below
      # verifies the graceful error path fires instead.
      started_at = System.monotonic_time(:millisecond)
      result = Codex.complete([Message.user("hang")], [], config)
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert {:error, reason} = result
      assert reason =~ "timed out"
      # Generous slack for TERM/KILL grace window and CI noise.
      assert elapsed < 5_000,
             "expected timeout to fire within ~200ms + grace, took #{elapsed}ms"
    end

    test "receive_timeout caps a larger timeout_ms for the real shell-backed run" do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "alloy-codex-provider-receive-timeout-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      auth_path = Path.join(temp_dir, "auth.json")
      File.write!(auth_path, "{}")

      script_path = Path.join(temp_dir, "slow-codex.sh")

      File.write!(script_path, """
      #!/bin/sh
      cat > /dev/null
      sleep 30
      """)

      File.chmod!(script_path, 0o755)

      config = %{
        model: "gpt-5.4",
        codex_bin: script_path,
        auth_path: auth_path,
        timeout_ms: 30_000,
        receive_timeout: 150
      }

      started_at = System.monotonic_time(:millisecond)
      result = Codex.complete([Message.user("deadline")], [], config)
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert {:error, "codex exec timed out after 150ms"} = result

      assert elapsed < 5_000,
             "expected receive_timeout to cap the port timeout, took #{elapsed}ms"
    end
  end

  describe "session continuation" do
    @thread "01a0e329-c415-74d3-a094-f28ef64e03cc"

    test "reports usage and the thread to resume from --json events" do
      config = %{model: "gpt-5.4", command_runner: fake_runner(json_reply("Hi back"))}
      messages = [Message.user("Hi")]

      assert {:ok, result} = Codex.complete(messages, [], config)

      assert result.usage == %{
               input_tokens: 26_486,
               output_tokens: 11,
               cache_read_input_tokens: 20_864,
               cache_creation_input_tokens: 0
             }

      prefix = messages ++ [Message.assistant("Hi back")]

      assert result.provider_state == %{
               session_id: @thread,
               sent_upto: 2,
               prefix_hash: :erlang.phash2(prefix)
             }
    end

    test "resumes the thread and sends only the messages it has not seen" do
      parent = self()
      earlier = [Message.user("Remember PLUM"), Message.assistant("OK")]
      messages = earlier ++ [Message.user("What was it?")]

      config = %{
        model: "gpt-5.4",
        provider_state: %{
          session_id: @thread,
          sent_upto: 2,
          prefix_hash: :erlang.phash2(earlier)
        },
        command_runner:
          fake_runner(fn args, opts, path ->
            send(parent, {:args, args})
            json_reply("PLUM").(args, opts, path)
          end)
      }

      assert {:ok, result} = Codex.complete(messages, [], config)
      assert_receive {:args, ["exec", "resume" | _] = args}

      prompt = List.last(args)
      assert Enum.at(args, -2) == @thread
      assert prompt =~ "What was it?"
      refute prompt =~ "Remember PLUM"
      refute "--ephemeral" in args
      assert result.provider_state.sent_upto == 4
    end

    test "sends the full transcript when earlier history was rewritten" do
      parent = self()
      messages = [Message.user("Compacted summary"), Message.assistant("OK"), Message.user("Go")]

      config = %{
        model: "gpt-5.4",
        provider_state: %{session_id: @thread, sent_upto: 2, prefix_hash: 0},
        command_runner:
          fake_runner(fn args, opts, path ->
            send(parent, {:args, args})
            json_reply("Going").(args, opts, path)
          end)
      }

      assert {:ok, _result} = Codex.complete(messages, [], config)
      assert_receive {:args, ["exec", "--skip-git-repo-check" | _] = args}
      assert List.last(args) =~ "Compacted summary"
    end

    test "falls back to the full transcript when the thread cannot be resumed" do
      parent = self()
      earlier = [Message.user("Remember PLUM"), Message.assistant("OK")]
      messages = earlier ++ [Message.user("What was it?")]

      config = %{
        model: "gpt-5.4",
        provider_state: %{session_id: @thread, sent_upto: 2, prefix_hash: :erlang.phash2(earlier)},
        command_runner:
          fake_runner(fn args, opts, path ->
            send(parent, {:args, args})

            case args do
              ["exec", "resume" | _] -> {"Error: thread not found", 1}
              _ -> json_reply("PLUM").(args, opts, path)
            end
          end)
      }

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> Codex.complete(messages, [], config) end)

      assert {:ok, %{messages: [%Message{content: "PLUM"}]}} = result
      assert log =~ "could not resume thread #{@thread}"
      assert_receive {:args, ["exec", "resume" | _]}
      assert_receive {:args, ["exec", "--skip-git-repo-check" | _] = fresh}
      assert List.last(fresh) =~ "Remember PLUM"
    end

    test "says a resumed turn resumed, and which thread" do
      earlier = [Message.user("Remember PLUM"), Message.assistant("OK")]

      config = %{
        model: "gpt-5.4",
        provider_state: %{session_id: @thread, sent_upto: 2, prefix_hash: :erlang.phash2(earlier)},
        command_runner: fake_runner(json_reply("PLUM"))
      }

      assert {:ok, result} = Codex.complete(earlier ++ [Message.user("What?")], [], config)

      assert result.response_metadata.session ==
               %{mode: :resumed, reason: nil, thread_id: @thread}
    end

    test "says why a turn went out fresh" do
      runner = fake_runner(json_reply("Hi"))
      messages = [Message.user("Summary"), Message.assistant("OK"), Message.user("Go")]

      first = %{model: "gpt-5.4", command_runner: runner}

      rewritten =
        %{
          first
          | command_runner: runner
        }
        |> Map.put(:provider_state, %{session_id: @thread, sent_upto: 2, prefix_hash: 0})

      assert {:ok, %{response_metadata: %{session: %{mode: :fresh, reason: :no_session}}}} =
               Codex.complete(messages, [], first)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> Codex.complete(messages, [], rewritten) end)

      assert {:ok, %{response_metadata: %{session: %{mode: :fresh, reason: :history_rewritten}}}} =
               result

      assert log =~ "starting a new thread"
    end

    test "says a turn went out fresh because its thread could not be resumed" do
      earlier = [Message.user("Remember PLUM"), Message.assistant("OK")]

      config = %{
        model: "gpt-5.4",
        provider_state: %{session_id: @thread, sent_upto: 2, prefix_hash: :erlang.phash2(earlier)},
        command_runner:
          fake_runner(fn args, opts, path ->
            case args do
              ["exec", "resume" | _] -> {"Error: thread not found", 1}
              _ -> json_reply("PLUM").(args, opts, path)
            end
          end)
      }

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          Codex.complete(earlier ++ [Message.user("What?")], [], config)
        end)

      assert {:ok, %{response_metadata: %{session: %{mode: :fresh, reason: :resume_failed}}}} =
               result
    end

    defp json_reply(text) do
      fn _args, _opts, output_path ->
        File.write!(
          output_path,
          Jason.encode!(%{stop_reason: "end_turn", text: text, tool_calls: []})
        )

        """
        {"type":"thread.started","thread_id":"#{@thread}"}
        {"type":"turn.started"}
        {"type":"turn.completed","usage":{"input_tokens":47350,"cached_input_tokens":20864,"cache_write_input_tokens":0,"output_tokens":11}}
        """
      end
    end
  end

  describe "stream/4" do
    test "replays the final assistant text through the callback" do
      parent = self()

      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            File.write!(
              output_path,
              ~s({"stop_reason":"end_turn","text":"Chunk me","tool_calls":[]})
            )

            "codex\n{\"stop_reason\":\"end_turn\"}\n"
          end)
      }

      assert {:ok, result} =
               Codex.stream([Message.user("Hi")], [], config, fn chunk ->
                 send(parent, {:chunk, chunk})
                 :ok
               end)

      assert_receive {:chunk, "Chunk me"}
      assert result.messages == [Message.assistant("Chunk me")]
    end

    test "hands on each message and command as Codex writes it, and does not replay the reply" do
      parent = self()
      reply = Jason.encode!(%{stop_reason: "end_turn", text: "Rivers flow.", tool_calls: []})

      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            File.write!(output_path, reply)

            Enum.map_join(
              [
                %{type: "thread.started", thread_id: "t-1"},
                %{
                  type: "item.completed",
                  item: %{type: "agent_message", text: "I'll look first.\n"}
                },
                %{type: "item.started", item: %{type: "command_execution", command: "ls"}},
                %{type: "item.completed", item: %{type: "agent_message", text: reply}},
                %{type: "turn.completed", usage: %{input_tokens: 10, output_tokens: 2}}
              ],
              "\n",
              &Jason.encode!/1
            )
          end)
      }

      assert {:ok, result} =
               Codex.stream([Message.user("Rivers?")], [], config, fn chunk ->
                 send(parent, {:chunk, chunk})
                 :ok
               end)

      assert_receive {:chunk, "I'll look first.\n"}
      assert_receive {:chunk, "\n$ ls\n"}
      assert_receive {:chunk, "Rivers flow."}
      refute_receive {:chunk, "Rivers flow."}
      assert result.messages == [Message.assistant("Rivers flow.")]
    end

    # The fake codex prints its first message and then waits for a file that
    # only the callback creates. Chunks handed on at exit would never create
    # it, and the turn would time out instead of finishing.
    test "hands on a message while the real process is still running" do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "alloy-codex-stream-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      auth_path = Path.join(temp_dir, "auth.json")
      File.write!(auth_path, "{}")
      go_path = Path.join(temp_dir, "go")
      script_path = Path.join(temp_dir, "fake-codex.sh")

      File.write!(script_path, """
      #!/bin/sh
      output=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--output-last-message" ]; then shift; output="$1"; fi
        shift
      done
      cat > /dev/null
      printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"working on it"}}'
      while [ ! -f "#{go_path}" ]; do sleep 0.05; done
      printf '%s' '{"stop_reason":"end_turn","text":"done","tool_calls":[]}' > "$output"
      printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"stop_reason\\":\\"end_turn\\",\\"text\\":\\"done\\",\\"tool_calls\\":[]}"}}'
      """)

      File.chmod!(script_path, 0o755)

      config = %{
        model: "gpt-5.4",
        codex_bin: script_path,
        auth_path: auth_path,
        timeout_ms: 10_000
      }

      parent = self()

      assert {:ok, result} =
               Codex.stream([Message.user("Go")], [], config, fn chunk ->
                 if chunk =~ "working on it", do: File.write!(go_path, "")
                 send(parent, {:chunk, chunk})
                 :ok
               end)

      assert_receive {:chunk, "working on it\n"}
      assert_receive {:chunk, "done"}
      assert result.messages == [Message.assistant("done")]
    end
  end

  defp fake_runner(fun) do
    fn _cmd, args, opts ->
      output_path = output_path!(args)

      case fun.(args, opts, output_path) do
        {output, status} when is_binary(output) and is_integer(status) -> {output, status}
        output when is_binary(output) -> {output, 0}
      end
    end
  end

  defp output_path!(args) do
    index = Enum.find_index(args, &(&1 == "--output-last-message"))
    Enum.at(args, index + 1)
  end
end
