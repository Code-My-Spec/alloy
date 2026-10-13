Logger.configure(level: :emergency)

defmodule LiveComparison do
  @moduledoc false

  @spec run(map()) :: map()
  def run(f) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    tools =
      File.read!("benchmarks/pi-agent/live/tools.json")
      |> Jason.decode!()
      |> Enum.map(fn spec ->
        Alloy.Tool.inline(
          name: spec["name"],
          description: spec["description"],
          input_schema:
            if(f["contract"] == "enum" and spec["name"] == "lookup",
              do:
                put_in(
                  spec["schema"],
                  ["properties", "key", "enum"],
                  Enum.sort(Map.keys(f["task"]["data"]))
                ),
              else: spec["schema"]
            ),
          execute: fn args, _ ->
            answer = execute(spec["name"], args, f["task"]["data"])
            Agent.update(log, &[%{name: spec["name"], args: args, result: answer} | &1])

            case answer do
              %{"error" => error} -> {:error, error}
              result -> {:ok, Jason.encode!(result)}
            end
          end
        )
      end)

    started = System.monotonic_time(:microsecond)

    try do
      {tag, result} =
        Alloy.stream(f["task"]["prompt"], fn _ -> :ok end,
          provider:
            {Alloy.Provider.Gemini,
             %{
               api_key: "benchmark-proxy",
               model: f["model"],
               api_url: f["url"],
               generation_config: %{
                 temperature: 0,
                 maxOutputTokens: 512,
                 thinkingConfig: %{thinkingBudget: 0}
               },
               tool_config: %{functionCallingConfig: %{mode: "AUTO"}},
               req_options: [retry: false, receive_timeout: 30_000]
             }},
          system_prompt: File.read!("benchmarks/pi-agent/live/system.txt"),
          tools: tools,
          tool_validation: :schema,
          tool_concurrency: 8,
          max_tokens: 1_048_576,
          max_turns: 8,
          max_retries: 0,
          timeout_ms: 120_000,
          stop_after_tool: if(f["policy"] == "stop", do: "submit_answer")
        )

      %{
        status: tag,
        error: result.error,
        text: result.text,
        turns: result.turns,
        stop_reason: result.stop_reason,
        usage: Map.from_struct(result.usage),
        tool_errors: Enum.count(result.tool_calls, &(&1[:error] != nil)),
        calls: Agent.get(log, &Enum.reverse/1),
        elapsed_ms: (System.monotonic_time(:microsecond) - started) / 1000
      }
    rescue
      error ->
        %{
          status: "error",
          error: Exception.message(error),
          elapsed_ms: (System.monotonic_time(:microsecond) - started) / 1000
        }
    after
      Agent.stop(log)
    end
  end

  defp execute("lookup", %{"key" => key}, data),
    do: Map.get(data, key, %{"error" => "unknown key"})

  defp execute("submit_answer", %{"answer" => answer}, _), do: answer

  defp execute("calculate", %{"op" => op, "a" => a, "b" => b}, _) do
    %{
      "value" =>
        case op do
          "add" -> a + b
          "subtract" -> a - b
          "multiply" -> a * b
        end
    }
  end
end

IO.puts("READY")

IO.stream(:stdio, :line)
|> Enum.each(fn line ->
  IO.puts(Jason.encode!(LiveComparison.run(Jason.decode!(line))))
end)
