defmodule Alloy.Tool.Spill do
  @moduledoc """
  A large tool result written to a file, with a notice in its place.

  Truncating a result keeps part of it and loses the rest, and a model that
  needed the lost part has no way back to it: a `cat a b c` that runs past the
  limit drops `c` and says only that something was cut. Spilling keeps all of
  it. The model is told where the full output is and shown its beginning and
  end, and can read the file in parts for anything else.

  Enabled with `:tool_result_spill` on `Alloy.Agent.Config`:

  - `:dir` (required) — where the files go. Relative paths resolve against the
    agent's `:working_directory`. Choose somewhere the agent's own file tools
    can read.
  - `:threshold` — results longer than this many characters are spilled
    (default `10_000`).
  - `:preview_chars` — characters shown from the start (default `2_000`).
  - `:tail_chars` — characters shown from the end, where errors and summaries
    usually are (default `1_000`).

  A tool whose `max_result_chars` is `:unlimited` is never spilled.
  """

  @type t :: %{
          dir: String.t(),
          threshold: pos_integer(),
          preview_chars: pos_integer(),
          tail_chars: non_neg_integer()
        }

  @defaults %{threshold: 10_000, preview_chars: 2_000, tail_chars: 1_000}

  @doc "The spill settings from `opts`, resolved against `working_directory`; nil when off."
  @spec normalize(keyword() | map() | nil, String.t()) :: t() | nil
  def normalize(nil, _working_directory), do: nil

  def normalize(opts, working_directory) when is_list(opts) or is_map(opts) do
    opts = Map.new(opts)

    dir =
      case Map.get(opts, :dir) do
        dir when is_binary(dir) and dir != "" -> Path.expand(dir, working_directory)
        other -> raise ArgumentError, "tool_result_spill needs a :dir, got: #{inspect(other)}"
      end

    @defaults
    |> Map.merge(Map.take(opts, [:threshold, :preview_chars, :tail_chars]))
    |> Map.put(:dir, dir)
    |> validate!()
  end

  defp validate!(%{threshold: t, preview_chars: p, tail_chars: tail} = spill)
       when is_integer(t) and t > 0 and is_integer(p) and p > 0 and is_integer(tail) and
              tail >= 0 and p + tail < t,
       do: spill

  defp validate!(spill) do
    raise ArgumentError,
          "tool_result_spill needs positive integers with preview_chars + tail_chars " <>
            "below threshold, got: #{inspect(Map.drop(spill, [:dir]))}"
  end

  @doc """
  The notice that replaces `text`, after writing `text` to a file named for the
  tool and call; `:keep` when `text` is within the threshold, `{:error, reason}`
  when the file could not be written.
  """
  @spec spill(String.t(), t(), String.t(), String.t() | nil) ::
          {:spilled, String.t()} | :keep | {:error, term()}
  def spill(text, %{threshold: threshold} = spill, tool_name, call_id) when is_binary(text) do
    length = String.length(text)

    if length <= threshold do
      :keep
    else
      path = Path.join(spill.dir, "#{safe(tool_name)}-#{safe(call_id)}.txt")

      with :ok <- File.mkdir_p(spill.dir),
           :ok <- File.write(path, text) do
        {:spilled, notice(text, length, path, spill)}
      end
    end
  end

  defp notice(text, length, path, %{preview_chars: preview, tail_chars: tail}) do
    head = String.slice(text, 0, preview)
    omitted = length - preview - tail

    tail_part =
      if tail > 0,
        do:
          "\n\n[... #{omitted} chars omitted ...]\n\nLast #{tail} chars:\n" <>
            String.slice(text, -tail, tail),
        else: "\n\n[... #{length - preview} chars omitted ...]"

    "Output too large (#{length} chars). Full output saved to: #{path}\n" <>
      "Read that file in parts (sed -n, grep) for anything not shown here.\n\n" <>
      "First #{preview} chars:\n" <> head <> tail_part
  end

  defp safe(nil), do: "call"
  defp safe(value), do: value |> to_string() |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
end
