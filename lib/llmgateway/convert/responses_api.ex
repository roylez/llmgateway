defmodule Llmgateway.Convert.ResponsesAPI do
  @moduledoc """
  Converts between OpenAI Chat Completions format and OpenAI Responses API format.

  The Responses API (`/responses`) uses a different request/response schema:
  - Request: `input` (string or array of messages) instead of `messages`
  - Request: `instructions` instead of system message
  - Response: `output` array with typed items instead of `choices`
  - Streaming: different event types

  Used for GitHub Copilot models that only support `/responses`.
  """

  @doc """
  Convert a Chat Completions request body to Responses API format.
  """
  def to_responses(body) when is_map(body) do
    {system, messages} = extract_system(body["messages"] || [])

    input = Enum.flat_map(messages, &convert_input_messages/1)

    result =
      %{"model" => body["model"], "input" => input}
      |> maybe_put("instructions", system)
      |> maybe_put("max_output_tokens", body["max_tokens"] || body["max_completion_tokens"])
      # `temperature` is dropped: Copilot /responses rejects it for reasoning models
      # (400 "Unsupported parameter: 'temperature'"; verified live with gpt-5.6-terra).
      |> maybe_put("top_p", body["top_p"])
      |> maybe_put("stream", body["stream"])
      |> convert_tools(body["tools"])
      |> convert_tool_choice(body["tool_choice"])
      |> convert_reasoning(body["reasoning_effort"])

    result
  end

  @doc """
  Convert a Responses API response to Chat Completions format.
  """
  def from_responses(body) when is_map(body) do
    output_items = body["output"] || []
    {text, tool_calls} = extract_output(output_items)
    finish_reason = convert_status(body["status"])

    message =
      %{"role" => "assistant"}
      |> maybe_put("content", text)
      |> maybe_put("tool_calls", tool_calls)

    usage = convert_usage(body["usage"])

    %{
      "id" => body["id"],
      "object" => "chat.completion",
      "created" => System.os_time(:second),
      "model" => body["model"],
      "choices" => [
        %{"index" => 0, "message" => message, "finish_reason" => finish_reason}
      ],
      "usage" => usage
    }
  end

  @doc """
  Convert a Responses API streaming event to a Chat Completions chunk.

  Returns `{:ok, chunk}`, `:skip`, or `:done`.
  """
  def stream_event_to_chunk(%{"type" => "response.created", "response" => resp}) do
    {:ok,
     %{
       "id" => resp["id"],
       "object" => "chat.completion.chunk",
       "created" => System.os_time(:second),
       "model" => resp["model"],
       "choices" => [
         %{
           "index" => 0,
           "delta" => %{"role" => "assistant", "content" => ""},
           "finish_reason" => nil
         }
       ]
     }}
  end

  def stream_event_to_chunk(%{"type" => "response.output_text.delta", "delta" => delta}) do
    {:ok,
     %{
       "object" => "chat.completion.chunk",
       "choices" => [
         %{"index" => 0, "delta" => %{"content" => delta}, "finish_reason" => nil}
       ]
     }}
  end

  def stream_event_to_chunk(%{"type" => "response.content_part.delta", "delta" => delta})
      when is_binary(delta) do
    {:ok,
     %{
       "object" => "chat.completion.chunk",
       "choices" => [
         %{"index" => 0, "delta" => %{"content" => delta}, "finish_reason" => nil}
       ]
     }}
  end

  def stream_event_to_chunk(%{"type" => "response.completed", "response" => resp}) do
    finish_reason =
      if has_function_call(resp["output"] || []),
        do: "tool_calls",
        else: convert_status(resp["status"])

    usage = convert_usage(resp["usage"])

    {:ok,
     %{
       "object" => "chat.completion.chunk",
       "choices" => [
         %{"index" => 0, "delta" => %{}, "finish_reason" => finish_reason}
       ],
       "usage" => usage
     }}
  end

  # Tool calls: /responses streams them as `output_item.added` (header with
  # name/id) followed by `function_call_arguments.delta` (partial JSON). Without
  # these clauses every tool call falls into the catch-all and is dropped, so a
  # tool-using model would stream only an empty `finish_reason: stop` turn.
  def stream_event_to_chunk(%{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "call_id" => call_id,
          "name" => name
        },
        "output_index" => idx
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
                 "id" => call_id,
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

  def stream_event_to_chunk(%{
        "type" => "response.function_call_arguments.delta",
        "delta" => args,
        "output_index" => idx
      })
      when is_binary(args) do
    {:ok,
     %{
       "object" => "chat.completion.chunk",
       "choices" => [
         %{
           "index" => 0,
           "delta" => %{
             "tool_calls" => [%{"index" => idx, "function" => %{"arguments" => args}}]
           },
           "finish_reason" => nil
         }
       ]
     }}
  end

  # Refusals carry assistant text the client should see; dropping them turns a
  # refusal into a silent empty stop.
  def stream_event_to_chunk(%{"type" => "response.refusal.delta", "delta" => text})
      when is_binary(text) do
    {:ok,
     %{
       "object" => "chat.completion.chunk",
       "choices" => [
         %{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}
       ]
     }}
  end

  def stream_event_to_chunk(%{"type" => "response.function_call_arguments.done"}), do: :skip
  def stream_event_to_chunk(%{"type" => "response.output_text.done"}), do: :skip
  def stream_event_to_chunk(%{"type" => "response.content_part.done"}), do: :skip
  def stream_event_to_chunk(%{"type" => "response.output_item.added"}), do: :skip
  def stream_event_to_chunk(%{"type" => "response.output_item.done"}), do: :skip
  def stream_event_to_chunk(%{"type" => "response.content_part.added"}), do: :skip
  def stream_event_to_chunk(%{"type" => "response.in_progress"}), do: :skip
  def stream_event_to_chunk(%{"type" => "response.created"}), do: :skip
  def stream_event_to_chunk(_), do: :skip

  # ── Request helpers ───────────────────────────────────────

  defp extract_system(messages) do
    {system_msgs, rest} =
      Enum.split_while(messages, fn
        %{"role" => "system"} -> true
        _ -> false
      end)

    system =
      case system_msgs do
        [] -> nil
        msgs -> Enum.map_join(msgs, "\n", & &1["content"])
      end

    {system, rest}
  end

  defp convert_input_message(%{"role" => "system", "content" => content}) when is_list(content) do
    # Join content blocks into string (Responses API uses "instructions" for system)
    text = content |> Enum.map_join("\n", &(&1["text"] || ""))
    %{"role" => "developer", "content" => text}
  end

  defp convert_input_message(%{"role" => "system", "content" => c}) do
    %{"role" => "developer", "content" => c}
  end

  defp convert_input_message(%{"role" => "tool", "tool_call_id" => id, "content" => c}) do
    %{"type" => "function_call_output", "call_id" => id, "output" => c || ""}
  end

  defp convert_input_message(%{"role" => "user", "content" => content} = msg) when is_list(content) do
    converted = Enum.map(content, &convert_content_block("user", &1))
    %{msg | "content" => converted}
  end

  defp convert_input_message(%{"role" => "assistant", "content" => content} = msg)
       when is_list(content) do
    converted = Enum.map(content, &convert_content_block("assistant", &1))
    %{msg | "content" => converted}
  end

  defp convert_input_message(msg), do: msg

  # A chat-completions assistant `tool_calls` entry becomes an explicit
  # `function_call` input item. Without it, Copilot /responses rejects the
  # following `function_call_output` ("No tool call found for function call
  # output with call_id ...", invalid_request_body — verified live).
  defp convert_input_messages(%{"role" => "assistant", "tool_calls" => tcs} = msg)
       when is_list(tcs) do
    # `tool_calls: []` is a no-op — drop the Chat-completions-only key and defer
    # to the plain assistant conversion so it can't leak into Responses input.
    if tcs == [] do
      [convert_input_message(Map.delete(msg, "tool_calls"))]
    else
      content_item =
        case msg["content"] do
          nil ->
            []

          "" ->
            []

          c when is_binary(c) ->
            [assistant_message_item([%{"type" => "output_text", "text" => c}])]

          blocks when is_list(blocks) ->
            [assistant_message_item(Enum.map(blocks, &convert_content_block("assistant", &1)))]

          _ ->
            []
        end

      call_items =
        Enum.map(tcs, fn tc ->
          %{
            "type" => "function_call",
            "call_id" => tc["id"],
            "name" => get_in(tc, ["function", "name"]),
            "arguments" => get_in(tc, ["function", "arguments"]) || "{}"
          }
        end)

      content_item ++ call_items
    end
  end

  defp convert_input_messages(msg), do: [convert_input_message(msg)]

  # /responses "message" input item used to carry preserved assistant content.
  defp assistant_message_item(content) do
    %{"type" => "message", "role" => "assistant", "content" => content}
  end

  # Responses API uses "input_text"/"output_text" instead of "text"
  defp convert_content_block("assistant", %{"type" => "text"} = block) do
    Map.put(block, "type", "output_text")
  end

  defp convert_content_block(_role, %{"type" => "text"} = block) do
    Map.put(block, "type", "input_text")
  end

  defp convert_content_block(_role, block), do: block

  defp convert_tools(result, nil), do: result
  defp convert_tools(result, []), do: result

  defp convert_tools(result, tools) when is_list(tools) do
    converted =
      Enum.map(tools, fn
        %{"type" => "function", "function" => func} ->
          %{
            "type" => "function",
            "name" => func["name"],
            "description" => func["description"] || "",
            "parameters" => func["parameters"] || %{}
          }

        tool ->
          tool
      end)

    Map.put(result, "tools", converted)
  end

  defp convert_tool_choice(result, nil), do: result
  defp convert_tool_choice(result, "auto"), do: Map.put(result, "tool_choice", "auto")
  defp convert_tool_choice(result, "none"), do: Map.put(result, "tool_choice", "none")
  defp convert_tool_choice(result, "required"), do: Map.put(result, "tool_choice", "required")
  defp convert_tool_choice(result, choice), do: Map.put(result, "tool_choice", choice)

  defp convert_reasoning(result, nil), do: result

  defp convert_reasoning(result, effort) when is_binary(effort) do
    Map.put(result, "reasoning", %{"effort" => effort})
  end

  defp convert_reasoning(result, _), do: result

  # ── Response helpers ──────────────────────────────────────

  defp extract_output(items) do
    {texts, tool_calls} =
      Enum.reduce(items, {[], []}, fn
        %{"type" => "message", "content" => content}, {ts, tcs} ->
          new_texts =
            content
            |> Enum.filter(&(&1["type"] == "output_text"))
            |> Enum.map(& &1["text"])

          {ts ++ new_texts, tcs}

        %{"type" => "function_call", "name" => name, "arguments" => args, "call_id" => id},
        {ts, tcs} ->
          tc = %{
            "id" => id,
            "type" => "function",
            "function" => %{"name" => name, "arguments" => args}
          }

          {ts, tcs ++ [tc]}

        _other, acc ->
          acc
      end)

    text = if texts == [], do: nil, else: Enum.join(texts, "")
    tool_calls = if tool_calls == [], do: nil, else: tool_calls
    {text, tool_calls}
  end

  defp has_function_call(output_items) when is_list(output_items) do
    Enum.any?(output_items, &(&1["type"] == "function_call"))
  end

  defp has_function_call(_), do: false

  defp convert_status("completed"), do: "stop"
  defp convert_status("incomplete"), do: "length"
  defp convert_status("failed"), do: "stop"
  defp convert_status(_), do: "stop"

  defp convert_usage(nil), do: nil

  defp convert_usage(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0

    %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => input + output
    }
  end

  # ── Helpers ───────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
