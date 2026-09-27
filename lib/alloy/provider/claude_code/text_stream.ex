defmodule Alloy.Provider.ClaudeCode.TextStream do
  @moduledoc false

  # Streams the reply text out of `claude -p --output-format stream-json`.
  #
  # With `--json-schema` the answer is not text: the model calls Claude Code's
  # StructuredOutput tool, and what streams is `input_json_delta` fragments of
  # `{"stop_reason": ..., "text": "...", "tool_calls": [...]}`. The reply the
  # caller wants is the growing `text` value inside that partial JSON, so each
  # fragment is appended to the tool input, the `text` string's prefix is decoded
  # again, and only what is new goes to `on_chunk`.
  #
  # Re-scanning the whole input per fragment is quadratic, and fine: it is one
  # reply, a few kilobytes.

  defstruct [:on_chunk, line: "", json: "", streamed: ""]

  @type t :: %__MODULE__{
          on_chunk: (String.t() -> any()),
          line: binary(),
          json: binary(),
          streamed: String.t()
        }

  @spec new((String.t() -> any())) :: t()
  def new(on_chunk) when is_function(on_chunk, 1), do: %__MODULE__{on_chunk: on_chunk}

  @doc false
  # Raw stdout, in whatever pieces the port delivers; lines can straddle them.
  @spec feed(t(), binary()) :: t()
  def feed(%__MODULE__{} = state, data) do
    [partial | complete] = (state.line <> data) |> String.split("\n") |> Enum.reverse()

    complete
    |> Enum.reverse()
    |> Enum.reduce(%{state | line: partial}, &handle_line/2)
  end

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"type" => "stream_event", "event" => %{"type" => "content_block_start"}}} ->
        %{state | json: ""}

      {:ok,
       %{
         "type" => "stream_event",
         "event" => %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "input_json_delta", "partial_json" => fragment}
         }
       }}
      when is_binary(fragment) ->
        emit(%{state | json: state.json <> fragment})

      _ ->
        state
    end
  end

  defp emit(state) do
    with text when is_binary(text) <- text_prefix(state.json),
         true <- byte_size(text) > byte_size(state.streamed),
         true <- String.starts_with?(text, state.streamed) do
      state.on_chunk.(
        binary_part(text, byte_size(state.streamed), byte_size(text) - byte_size(state.streamed))
      )

      %{state | streamed: text}
    else
      _ -> state
    end
  end

  @doc false
  # The decoded prefix of the top-level `"text"` string in a partial JSON
  # object, or nil before it starts.
  @spec text_prefix(binary()) :: String.t() | nil
  def text_prefix(json) do
    case walk(json, 0, nil, :key) do
      {:ok, raw} -> decode(raw)
      :none -> nil
    end
  end

  # Depth 1 is the payload object: a string there is a key until a `:` makes
  # the next one its value, and a `,` goes back to keys. Nested strings (tool
  # call arguments may well have a "text" key) are skipped whole.
  defp walk(<<>>, _depth, _key, _mode), do: :none
  defp walk(<<?", rest::binary>>, 1, "text", :value), do: {:ok, raw_prefix(rest, <<>>)}

  defp walk(<<?", rest::binary>>, depth, key, mode) do
    case read_string(rest, <<>>) do
      :eof ->
        :none

      {raw, rest} ->
        key = if depth == 1 and mode == :key, do: raw, else: key
        walk(rest, depth, key, mode)
    end
  end

  defp walk(<<?:, rest::binary>>, 1, key, :key), do: walk(rest, 1, key, :value)
  defp walk(<<?,, rest::binary>>, 1, _key, _mode), do: walk(rest, 1, nil, :key)

  defp walk(<<c, rest::binary>>, depth, key, mode) when c in [?{, ?[],
    do: walk(rest, depth + 1, key, mode)

  defp walk(<<c, rest::binary>>, depth, key, mode) when c in [?}, ?]],
    do: walk(rest, depth - 1, key, mode)

  defp walk(<<_c, rest::binary>>, depth, key, mode), do: walk(rest, depth, key, mode)

  defp read_string(<<?\\, c, rest::binary>>, acc), do: read_string(rest, <<acc::binary, ?\\, c>>)
  defp read_string(<<?", rest::binary>>, acc), do: {acc, rest}
  defp read_string(<<c, rest::binary>>, acc), do: read_string(rest, <<acc::binary, c>>)
  defp read_string(_eof, _acc), do: :eof

  # The string's raw content so far, cut before an escape that has not finished
  # arriving.
  defp raw_prefix(<<?\\, c, rest::binary>>, acc), do: raw_prefix(rest, <<acc::binary, ?\\, c>>)
  defp raw_prefix(<<?", _rest::binary>>, acc), do: acc
  defp raw_prefix(<<?\\>>, acc), do: acc
  defp raw_prefix(<<c, rest::binary>>, acc), do: raw_prefix(rest, <<acc::binary, c>>)
  defp raw_prefix(<<>>, acc), do: acc

  # A `\uXXXX` still arriving, or the high half of a surrogate pair whose low
  # half has not, is held back until it can decode.
  defp decode(raw) do
    raw = Regex.replace(~r/\\u[0-9a-fA-F]{0,3}$/, raw, "")

    case Jason.decode(~s(") <> raw <> ~s(")) do
      {:ok, text} ->
        text

      {:error, _} ->
        case Jason.decode(~s(") <> Regex.replace(~r/\\u[0-9a-fA-F]{4}$/, raw, "") <> ~s(")) do
          {:ok, text} -> text
          {:error, _} -> nil
        end
    end
  end
end
