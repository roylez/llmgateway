defmodule Llmgateway.Convert.AnthropicToOpenAI do
  @moduledoc """
  Converts Anthropic messages API responses to OpenAI chat/completions format.

  Handles both non-streaming responses and individual streaming events.
  """

  @stop_reason_map %{
    "end_turn" => "stop",
    "stop_sequence" => "stop",
    "max_tokens" => "length",
    "tool_use" => "tool_calls"
  }

  # ── Non-streaming response ────────────────────────────────

  @doc """
  Convert a full Anthropic response body to OpenAI chat/completions format.
  """
  def convert_response(body) when is_map(body) do
    content_blocks = body["content"] || []
    {text, tool_calls} = extract_content(content_blocks)
    finish_reason = Map.get(@stop_reason_map, body["stop_reason"], "stop")

    message =
      %{"role" => body["role"] || "assistant"}
      |> maybe_put("content", text)
      |> maybe_put("tool_calls", tool_calls)

    usage = convert_usage(body["usage"])

    %{
      "id" => body["id"] || "chatcmpl-#{random_id()}",
      "object" => "chat.completion",
      "created" => System.os_time(:second),
      "model" => body["model"],
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => finish_reason
        }
      ],
      "usage" => usage
    }
  end

  # ── Streaming event conversion ────────────────────────────

  @doc """
  Convert an Anthropic SSE stream event to OpenAI SSE format.

  Anthropic events: message_start, content_block_start, content_block_delta,
  content_block_stop, message_delta, message_stop

  Returns `{:ok, openai_chunk}` or `:skip` for events with no OpenAI equivalent.
  """
  def convert_stream_event(%{"type" => "message_start", "message" => msg}) do
    {:ok,
     %{
       "id" => msg["id"],
       "object" => "chat.completion.chunk",
       "created" => System.os_time(:second),
       "model" => msg["model"],
       "choices" => [
         %{
           "index" => 0,
           "delta" => %{"role" => "assistant", "content" => ""},
           "finish_reason" => nil
         }
       ]
     }}
  end

  def convert_stream_event(%{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => text},
        "index" => _idx
      }) do
    {:ok,
     %{
       "object" => "chat.completion.chunk",
       "choices" => [
         %{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}
       ]
     }}
  end

  def convert_stream_event(%{
        "type" => "content_block_delta",
        "delta" => %{"type" => "input_json_delta", "partial_json" => json},
        "index" => idx
      }) do
    {:ok,
     %{
       "object" => "chat.completion.chunk",
       "choices" => [
         %{
           "index" => 0,
           "delta" => %{
             "tool_calls" => [%{"index" => idx, "function" => %{"arguments" => json}}]
           },
           "finish_reason" => nil
         }
       ]
     }}
  end

  def convert_stream_event(%{
        "type" => "content_block_start",
        "content_block" => %{"type" => "tool_use", "id" => id, "name" => name},
        "index" => idx
      }) do
    {:ok,
     %{
       "object" => "chat.completion.chunk",
       "choices" => [
         %{
           "index" => 0,
           "delta" => %{
             "tool_calls" => [
               %{
                 "index" => idx,
                 "id" => id,
                 "type" => "function",
                 "function" => %{"name" => name, "arguments" => ""}
               }
             ]
           },
           "finish_reason" => nil
         }
       ]
     }}
  end

  def convert_stream_event(%{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => stop_reason},
        "usage" => usage
      }) do
    finish_reason = Map.get(@stop_reason_map, stop_reason, "stop")

    {:ok,
     %{
       "object" => "chat.completion.chunk",
       "choices" => [
         %{"index" => 0, "delta" => %{}, "finish_reason" => finish_reason}
       ],
       "usage" => convert_usage(usage)
     }}
  end

  def convert_stream_event(%{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => stop_reason}
      }) do
    finish_reason = Map.get(@stop_reason_map, stop_reason, "stop")

    {:ok,
     %{
       "object" => "chat.completion.chunk",
       "choices" => [
         %{"index" => 0, "delta" => %{}, "finish_reason" => finish_reason}
       ]
     }}
  end

  # Skip events with no OpenAI equivalent
  def convert_stream_event(%{"type" => "content_block_start"}), do: :skip
  def convert_stream_event(%{"type" => "content_block_stop"}), do: :skip
  def convert_stream_event(%{"type" => "message_stop"}), do: :skip
  def convert_stream_event(%{"type" => "ping"}), do: :skip
  def convert_stream_event(_), do: :skip

  # ── Content extraction ────────────────────────────────────

  defp extract_content(blocks) do
    {texts, tool_uses} =
      Enum.reduce(blocks, {[], []}, fn
        %{"type" => "text", "text" => text}, {ts, tus} ->
          {[text | ts], tus}

        %{"type" => "tool_use"} = block, {ts, tus} ->
          {ts, [anthropic_tool_use_to_openai(block) | tus]}

        _other, acc ->
          acc
      end)

    text =
      case Enum.reverse(texts) do
        [] -> nil
        parts -> Enum.join(parts, "")
      end

    tool_calls =
      case Enum.reverse(tool_uses) do
        [] -> nil
        calls -> calls
      end

    {text, tool_calls}
  end

  defp anthropic_tool_use_to_openai(%{"id" => id, "name" => name, "input" => input}) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => Jason.encode!(input)
      }
    }
  end

  # ── Usage conversion ──────────────────────────────────────

  defp convert_usage(nil), do: nil

  defp convert_usage(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0

    result = %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => input + output
    }

    # Cache token exposure
    cache_read = usage["cache_read_input_tokens"]
    cache_creation = usage["cache_creation_input_tokens"]

    if cache_read || cache_creation do
      details =
        %{}
        |> maybe_put("cached_tokens", cache_read)
        |> maybe_put("cache_creation_tokens", cache_creation)

      Map.put(result, "prompt_tokens_details", details)
    else
      result
    end
  end

  # ── Helpers ───────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp random_id do
    :crypto.strong_rand_bytes(12) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
