alias Alloy.Agent.{Config, State}
alias Alloy.Tool.{Executor, Validation}

schema = %{
  "type" => "object",
  "properties" => %{"value" => %{"type" => "integer"}},
  "required" => ["value"],
  "additionalProperties" => false
}

input = %{"value" => 1}
root = ExJsonSchema.Schema.resolve(schema)

tool =
  Alloy.Tool.inline(
    name: "work",
    description: "Echo",
    input_schema: schema,
    execute: fn _, _ -> {:ok, "1"} end
  )

state =
  State.init(
    Config.from_opts(provider: Alloy.Provider.Test, tools: [tool], tool_validation: :schema)
  )

{_, cache} = Validation.prepare(state.tool_fns, :schema, %{})
state = %{state | tool_schema_cache: cache}
call = %{name: "work", id: "c1", input: input}

rows =
  for {name, fun} <- [
        {"schema_cold", fn -> ExJsonSchema.Schema.resolve(schema) end},
        {"validate_resolved", fn -> ExJsonSchema.Validator.validate(root, input) end},
        {"json_normalize", fn -> input |> Jason.encode!(maps: :strict) |> Jason.decode!() end},
        {"cached_schema_lookup", fn -> Validation.prepare(state.tool_fns, :schema, cache) end},
        {"supervised_task",
         fn ->
           Alloy.TaskSupervisor |> Task.Supervisor.async_nolink(fn -> "1" end) |> Task.await()
         end},
        {"executor_cached_schema",
         fn -> {:ok, _, _} = Executor.execute_all([call], state.tool_fns, state, []) end}
      ] do
    for _ <- 1..100, do: fun.()

    samples =
      for _ <- 1..1000 do
        start = System.monotonic_time()
        fun.()
        System.convert_time_unit(System.monotonic_time() - start, :native, :nanosecond) / 1000
      end
      |> Enum.sort()

    %{
      name: name,
      median_us: Enum.at(samples, 500),
      p95_us: Enum.at(samples, 950),
      samples_us: samples
    }
  end

IO.puts(Jason.encode!(%{engine: "alloy", rows: rows}))
