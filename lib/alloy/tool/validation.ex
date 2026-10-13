defmodule Alloy.Tool.Validation do
  @moduledoc false

  alias Alloy.Tool.Registry
  alias ExJsonSchema.Schema
  alias ExJsonSchema.Validator

  # Optional dependency: consumers using required-key validation need not install it.
  @compile {:no_warn_undefined, [ExJsonSchema.Schema, ExJsonSchema.Validator]}

  @spec prepare(map(), :required | :schema, map()) :: {map(), map()}
  def prepare(_tools, :required, _cache), do: {%{}, %{}}

  def prepare(tools, :schema, cache) do
    unless Code.ensure_loaded?(Schema) do
      raise ArgumentError,
            "tool_validation: :schema requires the optional :ex_json_schema dependency"
    end

    # Retain only the current tool set, keyed by exact schema contents. Comparing
    # before JSON normalization preserves duplicate-key rejection on cache misses.
    cache =
      Map.new(tools, fn {name, tool} ->
        source = tool |> Registry.to_inline() |> Map.fetch!(:input_schema)

        entry =
          case Map.get(cache, name) do
            {^source, resolved} ->
              {source, resolved}

            _ ->
              schema = json(source)
              local_refs!(schema)
              {source, Schema.resolve(schema)}
          end

        {name, entry}
      end)

    {Map.new(cache, fn {name, {_source, resolved}} -> {name, resolved} end), cache}
  end

  @spec check(map(), String.t(), map()) :: :ok | {:error, String.t(), nil}
  def check(input, name, schemas) do
    case Map.fetch(schemas, name) do
      :error -> :ok
      {:ok, schema} -> validate(schema, json(input), name)
    end
  rescue
    error in Jason.EncodeError ->
      {:error, "Invalid input for #{name}: #{Exception.message(error)}", nil}
  end

  defp validate(schema, input, name) do
    case Validator.validate(schema, input) do
      :ok ->
        :ok

      {:error, errors} ->
        details = Enum.map_join(errors, "; ", fn {error, path} -> "#{path}: #{error}" end)
        {:error, "Invalid input for #{name}: #{details}", nil}
    end
  end

  defp json(value), do: value |> Jason.encode!(maps: :strict) |> Jason.decode!()

  defp local_refs!(map) when is_map(map) do
    case Map.get(map, "$ref") do
      nil -> :ok
      "#" <> _fragment -> :ok
      ref -> raise ArgumentError, "tool schemas require local $ref values, got: #{inspect(ref)}"
    end

    Enum.each(Map.values(map), &local_refs!/1)
  end

  defp local_refs!(list) when is_list(list), do: Enum.each(list, &local_refs!/1)
  defp local_refs!(_value), do: :ok
end
