defmodule MinimalHost.OutputCapture do
  @moduledoc """
  Host-owned bounded capture at a streaming producer, before tool truncation.

  The host supplies an existing private directory and owns retention, retrieval,
  tenant separation and aggregate disk quotas. Each capture has an explicit byte
  ceiling. Synchronous writes backpressure the producer; no unbounded queue is
  introduced here. Upstream producers must also bound their chunk buffers.
  """

  @spec capture(Enumerable.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def capture(chunks, directory, opts) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    preview_bytes = Keyword.fetch!(opts, :preview_bytes)

    unless is_integer(max_bytes) and max_bytes > 0 and is_integer(preview_bytes) and
             preview_bytes > 0 do
      raise ArgumentError, "positive max_bytes and preview_bytes are required"
    end

    with :ok <- private_directory(directory) do
      path =
        Path.join(
          directory,
          Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false) <> ".txt"
        )

      write_capture(chunks, path, max_bytes, preview_bytes)
    end
  end

  defp private_directory(directory) do
    case File.lstat(directory) do
      {:ok, %{type: :directory, mode: mode}} ->
        if Bitwise.band(mode, 0o077) == 0, do: :ok, else: {:error, :directory_not_private}

      {:ok, _other} ->
        {:error, :not_a_directory}

      {:error, _reason} = error ->
        error
    end
  end

  defp write_capture(chunks, path, max_bytes, preview_bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        try do
          with :ok <- File.chmod(path, 0o600),
               {:ok, captured} <- write_chunks(chunks, file, max_bytes, preview_bytes),
               :ok <- File.close(file) do
            {:ok,
             captured |> Map.update!(:preview, &String.replace_invalid/1) |> Map.put(:path, path)}
          else
            {:error, reason} ->
              _ = File.rm(path)
              {:error, reason}
          end
        catch
          kind, reason ->
            _ = File.rm(path)
            :erlang.raise(kind, reason, __STACKTRACE__)
        after
          _ = File.close(file)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp write_chunks(chunks, file, max_bytes, preview_bytes) do
    Enum.reduce_while(chunks, {:ok, %{bytes: 0, preview: ""}}, fn chunk, {:ok, captured} ->
      total = captured.bytes + byte_size(chunk)

      if total > max_bytes do
        {:halt, {:error, :output_limit}}
      else
        case :file.write(file, chunk) do
          :ok ->
            remaining = max(preview_bytes - byte_size(captured.preview), 0)
            preview = captured.preview <> binary_part(chunk, 0, min(byte_size(chunk), remaining))
            {:cont, {:ok, %{bytes: total, preview: preview}}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end
    end)
  end
end
