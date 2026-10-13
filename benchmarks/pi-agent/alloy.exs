defmodule Comparison.Provider do
  @moduledoc false
  @behaviour Alloy.Provider

  alias Alloy.Provider.Test

  @impl Alloy.Provider
  @spec complete([Alloy.Message.t()], [map()], map()) :: {:ok, map()}
  def complete(_messages, _tools, %{fixture: f, counters: counters}) do
    request = :atomics.add_get(counters, 1, 1)

    if request <= f["rounds"] do
      Test.tool_use_response(
        for i <- 1..f["batch"] do
          %{
            id: "c#{request}-#{i}",
            name: if(f["mode"] == "mixed_stop" and i == 2, do: "other", else: "work"),
            input: %{
              "value" =>
                cond do
                  f["mode"] == "invalid" -> "bad"
                  f["mode"] == "coercion" -> "1"
                  true -> i
                end
            }
          }
        end
      )
    else
      Test.text_response("done")
    end
  end
end

defmodule Comparison.Hooks do
  @moduledoc false
  @behaviour Alloy.Middleware

  @impl Alloy.Middleware
  @spec call(Alloy.Middleware.hook(), Alloy.Agent.State.t()) :: Alloy.Middleware.call_result()
  def call(:before_tool_call, %{config: %{context: %{mode: "blocked"}}}), do: {:block, "denied"}

  def call(:after_tool_call, %{config: %{context: %{mode: "redacted"}}} = state) do
    {:result, %{state.config.context.current_tool_result | content: "redacted", data: nil}}
  end

  def call(_, state), do: state
end

defmodule Comparison do
  @moduledoc false

  @spec run(map()) :: map()
  def run(%{"agents" => agents} = f) do
    outcomes =
      1..agents
      |> Task.async_stream(fn _ -> run_one(f) end, max_concurrency: agents, timeout: 30_000)
      |> Enum.map(fn {:ok, outcome} -> outcome end)

    %{
      requests: Enum.sum(Enum.map(outcomes, & &1.requests)),
      executions: Enum.sum(Enum.map(outcomes, & &1.executions)),
      results: Enum.flat_map(outcomes, & &1.results)
    }
  end

  def run(f), do: run_one(f)

  @spec run_one(map()) :: map()
  def run_one(f) do
    counters = :atomics.new(2, [])

    tool =
      Alloy.Tool.inline(
        name: "work",
        description: "Echo an integer",
        input_schema: %{
          type: "object",
          properties: %{value: %{type: "integer"}},
          required: ["value"],
          additionalProperties: false
        },
        execute: fn input, _ ->
          :atomics.add(counters, 2, 1)
          if f["delay_ms"] > 0, do: Process.sleep(f["delay_ms"])

          if f["mode"] in ["failure", "failed_stop"],
            do: {:error, "failed"},
            else: {:ok, Integer.to_string(input["value"])}
        end
      )

    {:ok, result} =
      Alloy.run("go",
        provider: {Comparison.Provider, %{fixture: f, counters: counters}},
        tools: if(f["mode"] == "mixed_stop", do: [tool, %{tool | name: "other"}], else: [tool]),
        middleware: [Comparison.Hooks],
        context: %{mode: f["mode"]},
        tool_validation: if(f["validation"] == "required", do: :required, else: :schema),
        tool_concurrency: if(f["parallel"], do: 8, else: 1),
        stop_after_tool: if(f["mode"] in ["stop", "mixed_stop", "failed_stop"], do: "work"),
        max_turns: 20
      )

    if result.status != :completed, do: raise("incomplete run")

    results =
      for m <- result.messages,
          is_list(m.content),
          b <- m.content,
          b[:type] == "tool_result",
          do: b

    %{
      requests: :atomics.get(counters, 1),
      executions: :atomics.get(counters, 2),
      results:
        Enum.map(results, fn b ->
          %{
            id: b.tool_use_id,
            error: b[:is_error] == true,
            content: if(b[:is_error], do: "<error>", else: b.content)
          }
        end)
    }
  end

  @spec main() :: :ok
  def main do
    fixtures = File.read!("benchmarks/pi-agent/fixtures.json") |> Jason.decode!()
    n = String.to_integer(System.get_env("BENCH_SAMPLES", "100"))

    rows =
      for f <- fixtures do
        outcome = run(f)
        for _ <- 1..20, do: run(f)

        samples =
          for _ <- 1..n do
            {us, actual} = :timer.tc(fn -> run(f) end)
            if actual != outcome, do: raise("nondeterministic result")
            us / 1000
          end

        %{name: f["name"], outcome: outcome, samples_ms: samples}
      end

    IO.puts(
      Jason.encode!(%{
        runtime: "Elixir #{System.version()} OTP #{System.otp_release()}",
        schedulers: System.schedulers_online(),
        rows: rows
      })
    )
  end
end

Comparison.main()
