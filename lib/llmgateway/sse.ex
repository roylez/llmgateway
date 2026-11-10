defmodule Llmgateway.SSE do
  @moduledoc """
  Shared streaming loop for OpenAI- and Anthropic-format SSE responses.

  Consumes a generator stream, writing a series of SSE frames per element.
  Handles the terminal protocol markers uniformly: `:done` is consumed (the
  `{:stream_stats, stats}` diagnostics element follows) and `{:stream_stats, _}`
  logs request stats then halts. Each non-terminal element is passed to
  `reduce`, which returns `{:ok, [frame], new_state}`, `{:skip, new_state}`, or
  `{:error, new_state}`.

  `flush` runs once at end of stream (on both terminal markers) and returns
  `{:ok, [frame], new_state}` or `{:skip, new_state}`. Anthropic uses it to
  emit the closing `message_delta` + `message_stop` after the upstream's
  late usage chunk has arrived.
  """
  import Plug.Conn

  require Logger

  def stream_loop(stream, conn, state, deployment, rid, reduce, usage_fun, flush \\ nil) do
    Enum.reduce_while(stream, {conn, state}, fn
      :done, {conn, state} ->
        # Keep consuming: {:stream_stats, stats} (with diagnostics) follows.
        case run_flush(conn, state, flush) do
          {:ok, conn, state} -> {:cont, {conn, state}}
          {:error, conn, state} -> {:halt, {conn, state}}
        end

      {:stream_stats, stats}, {conn, state} ->
        {_status, conn, state} = run_flush(conn, state, flush)
        Llmgateway.Stream.log_stats(deployment, rid, stats, usage_fun.(state))
        {:halt, {conn, state}}

      data, {conn, state} ->
        case reduce.(data, state) do
          {:ok, frames, new_state} ->
            case write_frames(conn, frames) do
              {:ok, conn} -> {:cont, {conn, new_state}}
              {:error, conn} -> {:halt, {conn, new_state}}
            end

          {:skip, new_state} ->
            {:cont, {conn, new_state}}

          {:error, new_state} ->
            {:halt, {conn, new_state}}
        end
    end)
  end

  # Runs the end-of-stream callback and writes whatever frames it produces.
  # Returns `{:error, conn, state}` when the client connection broke; stats are
  # logged either way.
  defp run_flush(conn, state, nil), do: {:ok, conn, state}

  defp run_flush(conn, state, flush) do
    case flush.(state) do
      {:ok, frames, new_state} ->
        case write_frames(conn, frames) do
          {:ok, conn} -> {:ok, conn, new_state}
          {:error, conn} -> {:error, conn, new_state}
        end

      {:skip, new_state} ->
        {:ok, conn, new_state}
    end
  end

  defp write_frames(conn, []), do: {:ok, conn}

  defp write_frames(conn, [frame | rest]) do
    case chunk(conn, frame) do
      {:ok, conn} -> write_frames(conn, rest)
      {:error, _} -> {:error, conn}
    end
  end
end
