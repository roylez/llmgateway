defmodule Llmgateway.SSE do
  @moduledoc """
  Shared streaming loop for OpenAI- and Anthropic-format SSE responses.

  Consumes a generator stream, writing a series of SSE frames per element.
  Handles the terminal protocol markers uniformly: `:done` is consumed (the
  `{:stream_stats, stats}` diagnostics element follows) and `{:stream_stats, _}`
  logs request stats then halts. Each non-terminal element is passed to
  `reduce`, which returns `{:ok, [frame], new_state}`, `{:skip, new_state}`, or
  `{:error, new_state}`.
  """
  import Plug.Conn

  require Logger

  def stream_loop(stream, conn, state, deployment, rid, reduce, usage_fun) do
    Enum.reduce_while(stream, {conn, state}, fn
      :done, acc ->
        # Keep consuming: {:stream_stats, stats} (with diagnostics) follows.
        {:cont, acc}

      {:stream_stats, stats}, {conn, state} ->
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

  defp write_frames(conn, []), do: {:ok, conn}

  defp write_frames(conn, [frame | rest]) do
    case chunk(conn, frame) do
      {:ok, conn} -> write_frames(conn, rest)
      {:error, _} = err -> err
    end
  end
end
