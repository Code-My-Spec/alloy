defmodule Alloy.Provider.RetryTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.State
  alias Alloy.Message
  alias Alloy.Provider.Retry

  describe "retryable?/1" do
    # HTTP status errors
    test "408 request timeout is retryable" do
      assert Retry.retryable?("HTTP 408: Request Timeout")
    end

    test "429 rate limit is retryable" do
      assert Retry.retryable?("HTTP 429: Too Many Requests")
    end

    test "500 server error is retryable" do
      assert Retry.retryable?("HTTP 500: Internal Server Error")
    end

    test "502 bad gateway is retryable" do
      assert Retry.retryable?("HTTP 502: Bad Gateway")
    end

    test "503 service unavailable is retryable" do
      assert Retry.retryable?("HTTP 503: Service Unavailable")
    end

    test "504 gateway timeout is retryable" do
      assert Retry.retryable?("HTTP 504: Gateway Timeout")
    end

    test "400 bad request is not retryable" do
      refute Retry.retryable?("HTTP 400: Bad Request")
    end

    test "401 unauthorized is not retryable" do
      refute Retry.retryable?("HTTP 401: Unauthorized")
    end

    # Provider-specific error formats
    test "a CLI provider's malformed reply is retryable" do
      assert Retry.retryable?(
               "malformed_reply: Claude Code returned tool_use without any tool calls"
             )
    end

    test "Anthropic rate_limit_error is retryable" do
      assert Retry.retryable?("rate_limit_error: rate limited")
    end

    test "OpenAI rate_limit_exceeded is retryable" do
      assert Retry.retryable?("rate_limit_exceeded: quota exceeded")
    end

    test "Anthropic overloaded_error is retryable" do
      assert Retry.retryable?("overloaded_error: model overloaded")
    end

    test "OpenAI server_error is retryable" do
      assert Retry.retryable?("server_error: internal error")
    end

    # Google Gemini errors
    test "Gemini RESOURCE_EXHAUSTED is retryable" do
      assert Retry.retryable?("RESOURCE_EXHAUSTED: quota exceeded")
    end

    test "Gemini INTERNAL is retryable" do
      assert Retry.retryable?("INTERNAL: server error")
    end

    test "Gemini UNAVAILABLE is retryable" do
      assert Retry.retryable?("UNAVAILABLE: service down")
    end

    # Network failures
    test "econnrefused is retryable" do
      assert Retry.retryable?("HTTP request failed: econnrefused")
    end

    test "connection closed is retryable" do
      assert Retry.retryable?("HTTP request failed: closed")
    end

    test "timeout in HTTP request is retryable" do
      assert Retry.retryable?("HTTP request failed: timeout")
    end

    test "unprocessed in HTTP request is retryable" do
      assert Retry.retryable?("HTTP request failed: unprocessed")
    end

    test "atom :timeout is retryable" do
      assert Retry.retryable?(:timeout)
    end

    # Non-retryable
    test "unknown string error is not retryable" do
      refute Retry.retryable?("unknown error")
    end

    test "atom :badarg is not retryable" do
      refute Retry.retryable?(:badarg)
    end

    test "nil is not retryable" do
      refute Retry.retryable?(nil)
    end
  end

  describe "call_with_retry/6" do
    test "returns success on first try" do
      config = retry_config()
      state = build_state(config)
      provider_config = %{system_prompt: nil}
      deadline = System.monotonic_time(:millisecond) + 10_000

      provider = success_provider()

      result =
        Retry.call_with_retry(state, provider, provider_config, false, fn _ -> :ok end, deadline)

      assert {:ok, %{stop_reason: :end_turn}} = result
    end

    test "retries on retryable error and succeeds" do
      config = retry_config(max_retries: 2, retry_backoff_ms: 1)
      state = build_state(config)
      provider_config = %{system_prompt: nil}
      deadline = System.monotonic_time(:millisecond) + 10_000

      # Use an agent to track call count
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      provider = counting_provider(counter, 1)

      result =
        Retry.call_with_retry(state, provider, provider_config, false, fn _ -> :ok end, deadline)

      assert {:ok, %{stop_reason: :end_turn}} = result
      assert Agent.get(counter, & &1) == 2
    end

    test "returns error after exhausting retries" do
      config = retry_config(max_retries: 1, retry_backoff_ms: 1)
      state = build_state(config)
      provider_config = %{system_prompt: nil}
      deadline = System.monotonic_time(:millisecond) + 10_000

      provider = always_fail_provider()

      result =
        Retry.call_with_retry(state, provider, provider_config, false, fn _ -> :ok end, deadline)

      assert {:error, "HTTP 500: Server Error"} = result
    end

    test "does not retry non-retryable errors" do
      config = retry_config(max_retries: 3, retry_backoff_ms: 1)
      state = build_state(config)
      provider_config = %{system_prompt: nil}
      deadline = System.monotonic_time(:millisecond) + 10_000

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      provider = non_retryable_fail_provider(counter)

      result =
        Retry.call_with_retry(state, provider, provider_config, false, fn _ -> :ok end, deadline)

      assert {:error, "HTTP 401: Unauthorized"} = result
      # Should only be called once (no retries)
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "a request's receive timeout" do
    test "is what is left of the deadline when the caller set none" do
      seen = call_reporting_receive_timeout(%{system_prompt: nil}, 60_000)
      assert seen > 50_000 and seen <= 60_000
    end

    # A long loop deadline would otherwise let a request that went quiet wait
    # out the whole loop.
    test "is capped by one the caller set" do
      config = %{system_prompt: nil, req_options: [receive_timeout: 2_000]}
      assert call_reporting_receive_timeout(config, :timer.hours(24)) == 2_000
    end

    test "never runs past the deadline, whatever the caller set" do
      config = %{system_prompt: nil, req_options: [receive_timeout: :timer.hours(1)]}
      assert call_reporting_receive_timeout(config, 60_000) <= 60_000
    end
  end

  defp call_reporting_receive_timeout(provider_config, deadline_in) do
    test = self()

    provider =
      Module.create(
        :"Elixir.Alloy.Provider.RetryTest.ReportingProvider#{System.unique_integer([:positive])}",
        quote do
          def complete(_messages, _tools, config) do
            send(unquote(test), {:receive_timeout, config.req_options[:receive_timeout]})
            {:ok, %{stop_reason: :end_turn, messages: [], usage: %{}}}
          end
        end,
        Macro.Env.location(__ENV__)
      )
      |> elem(1)

    deadline = System.monotonic_time(:millisecond) + deadline_in
    state = build_state(retry_config())

    {:ok, _} =
      Retry.call_with_retry(state, provider, provider_config, false, fn _ -> :ok end, deadline)

    assert_received {:receive_timeout, seen}
    seen
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp retry_config(overrides \\ []) do
    defaults = [
      max_retries: 3,
      retry_backoff_ms: 1,
      fallback_providers: []
    ]

    merged = Keyword.merge(defaults, overrides)

    %Alloy.Agent.Config{
      provider: Alloy.Provider.Test,
      provider_config: %{},
      max_retries: merged[:max_retries],
      retry_backoff_ms: merged[:retry_backoff_ms],
      fallback_providers: merged[:fallback_providers]
    }
  end

  defp build_state(config) do
    State.init(config, [Message.user("test")])
  end

  defp success_provider do
    Module.create(
      :"Elixir.Alloy.Provider.RetryTest.SuccessProvider#{System.unique_integer([:positive])}",
      quote do
        def complete(_messages, _tools, _config) do
          {:ok, %{stop_reason: :end_turn, messages: [], usage: %{}}}
        end
      end,
      Macro.Env.location(__ENV__)
    )
    |> elem(1)
  end

  defp always_fail_provider do
    Module.create(
      :"Elixir.Alloy.Provider.RetryTest.AlwaysFailProvider#{System.unique_integer([:positive])}",
      quote do
        def complete(_messages, _tools, _config) do
          {:error, "HTTP 500: Server Error"}
        end
      end,
      Macro.Env.location(__ENV__)
    )
    |> elem(1)
  end

  defp counting_provider(counter, fail_count) do
    # Use Agent to track state across calls
    Module.create(
      :"Elixir.Alloy.Provider.RetryTest.CountingProvider#{System.unique_integer([:positive])}",
      quote do
        def complete(_messages, _tools, _config) do
          count = Agent.get_and_update(unquote(counter), fn c -> {c, c + 1} end)

          if count < unquote(fail_count) do
            {:error, "HTTP 500: Server Error"}
          else
            {:ok, %{stop_reason: :end_turn, messages: [], usage: %{}}}
          end
        end
      end,
      Macro.Env.location(__ENV__)
    )
    |> elem(1)
  end

  defp non_retryable_fail_provider(counter) do
    Module.create(
      :"Elixir.Alloy.Provider.RetryTest.NonRetryableProvider#{System.unique_integer([:positive])}",
      quote do
        def complete(_messages, _tools, _config) do
          Agent.update(unquote(counter), &(&1 + 1))
          {:error, "HTTP 401: Unauthorized"}
        end
      end,
      Macro.Env.location(__ENV__)
    )
    |> elem(1)
  end
end
