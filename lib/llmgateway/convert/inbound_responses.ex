defmodule Llmgateway.Convert.InboundResponses do
  @moduledoc """
  Converts inbound OpenAI Responses API (`/responses`) requests to the canonical
  OpenAI chat/completions format, and converts chat/completions responses back to
  Responses API format for the client.

  This is the reverse of `Llmgateway.Convert.ResponsesAPI` — here the CLIENT
  speaks the Responses API and the proxy normalizes to chat/completions internally.

  ## Request mapping
  - `input` (string or array of typed items) → `messages`
  - `instructions` → leading `system` message
  - `max_output_tokens` → `max_tokens`
  - `reasoning.effort` → `reasoning_effort`
  - `tools` (flat function defs) → chat `tools` (`{type, function}` wrappers)

  ## Response mapping
  - `choices[0].message` → `output` array of typed items (`message` / `function_call`)
  - `finish_reason` → `status`
  - `usage` (`prompt_tokens`/`completion_tokens`) → `input_tokens`/`output_tokens`
  """

  # ── Inbound: Responses API request → chat/completions canonical ─────

  @doc """
  Convert a Responses API request body to OpenAI chat/completions format.
  """
  def to_canonical(body) when is_map(body) do
    messages = build_messages(body["instructions"], body["input"])
    {tools, tool_choice} = convert_tools(body["tools"], body["tool_choice"])

    %{"model" => body["model"], "messages" => messages}
    |> maybe_put("max_tokens", body["max_output_tokens"])
    |> maybe_put("temperature", body["temperature"])
    |> maybe_put("top_p", body["top_p"])
    |> maybe_put("stream", body["stream"])
    |> maybe_put("tools", tools)
    |> maybe_put("tool_choice", tool_choice)
    |> maybe_put("reasoning_effort", get_in(body, ["reasoning", "effort"]))
    |> maybe_put("user", body["user"])
  end

  # input may be a plain string, or an array of typed items.
  defp build_messages(instructions, input) when is_binary(input) do
    build_messages(instructions, [%{"role" => "user", "content" => input}])
  end

  defp build_messages(instructions, input) when is_list(input) do
    msgs = Enum.flat_map(input, &item_to_messages/1)

    case instructions do
      nil -> msgs
      "" -> msgs
      text -> [%{"role" => "system", "content" => text} | msgs]
    end
  end

  defp build_messages(instructions, _nil) do
    build_messages(instructions, [])
  end

  # A typed message item: %{type: "message", role, content: [%{type, text}]}
  # or a bare chat-style message %{role, content}.
  defp item_to_messages(%{"type" => "function_call_output", "call_id" => id, "output" => out}) do
    [%{"role" => "tool", "tool_call_id" => id, "content" => out || ""}]
  end

  defp item_to_messages(%{
         "type" => "function_call",
         "call_id" => id,
         "name" => name,
         "arguments" => args
       }) do
    [
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => id,
            "type" => "function",
            "function" => %{"name" => name, "arguments" => args || "{}"}
          }
        ]
      }
    ]
  end

  defp item_to_messages(%{"role" => role, "content" => content} = item) do
    [%{"role" => normalize_role(role), "content" => content_to_text(role, content)}]
    |> maybe_put_tool_calls(item)
  end

  defp item_to_messages(_other), do: []

  # Responses "developer" role maps to chat "system".
  defp normalize_role("developer"), do: "system"
  defp normalize_role(role), do: role

  # Content may be a string or an array of typed blocks.
  defp content_to_text(_role, content) when is_binary(content), do: content

  defp content_to_text(_role, content) when is_list(content) do
    text =
      content
      |> Enum.filter(&text_block?/1)
      |> Enum.map_join("", & &1["text"])

    images = Enum.filter(content, &(&1["type"] == "input_image"))

    case images do
      [] ->
        text

      _ ->
        # Multimodal: emit chat content blocks (text + images).
        text_blocks = if text == "", do: [], else: [%{"type" => "text", "text" => text}]

        image_blocks =
          Enum.map(images, fn img ->
            %{"type" => "image_url", "image_url" => %{"url" => img["image_url"] || img["url"]}}
          end)

        text_blocks ++ image_blocks
    end
  end

  defp content_to_text(_role, nil), do: nil

  defp text_block?(%{"type" => t}) when t in ["input_text", "output_text", "text"], do: true
  defp text_block?(_), do: false

  # A bare assistant message item may carry chat-style tool_calls already.
  defp maybe_put_tool_calls([msg], %{"tool_calls" => tcs}) when is_list(tcs) and tcs != [] do
    [Map.put(msg, "tool_calls", tcs)]
  end

  defp maybe_put_tool_calls(msgs, _item), do: msgs

  # Responses tools are flat function definitions; chat wraps them.
  defp convert_tools(nil, choice), do: {nil, convert_tool_choice(choice)}
  defp convert_tools([], choice), do: {nil, convert_tool_choice(choice)}

  defp convert_tools(tools, choice) when is_list(tools) do
    converted =
      Enum.map(tools, fn
        %{"type" => "function", "function" => _} = already -> already
        %{"type" => "function", "name" => _} = flat -> wrap_function(flat)
        %{"name" => _} = flat -> wrap_function(flat)
        other -> other
      end)

    {converted, convert_tool_choice(choice)}
  end

  defp convert_tools(_tools, choice), do: {nil, convert_tool_choice(choice)}

  defp wrap_function(flat) do
    %{
      "type" => "function",
      "function" => %{
        "name" => flat["name"],
        "description" => flat["description"] || "",
        "parameters" => flat["parameters"] || %{}
      }
    }
  end

  # "auto"/"none"/"required" and structured choices all pass through unchanged.
  defp convert_tool_choice(choice), do: choice

  # ── Streaming: chat/completions chunk → Responses API SSE events ────
  @doc """
  Convert one OpenAI chat.completion.chunk to a list of Responses API events.

  Emits a minimal but well-formed sequence a Responses client can consume:
  `response.created` once, `response.output_text.delta` per text delta, and
  `response.completed` on finish. Returns `{events, new_state}`.
  """
  def chunk_to_responses_events(chunk, state \\ %{}) do
    choice = List.first(chunk["choices"] || []) || %{}
    delta = choice["delta"] || %{}
    finish = choice["finish_reason"]

    resp_id = state[:resp_id] || chunk["id"] || "resp_#{random_id()}"
    model = chunk["model"] || state[:model]

    state =
      state
      |> Map.put(:resp_id, resp_id)
      |> Map.put(:model, model)

    # Emit response.created only on the first chunk of the stream.
    created_events =
      if state[:started] do
        []
      else
        [
          %{
            "type" => "response.created",
            "response" => %{
              "id" => resp_id,
              "object" => "response",
              "created_at" => System.os_time(:second),
              "status" => "in_progress",
              "model" => model,
              "output" => []
            }
          }
        ]
      end

    state = Map.put(state, :started, true)

    text_events =
      case delta["content"] do
        text when is_binary(text) and text != "" ->
          [%{"type" => "response.output_text.delta", "delta" => text}]

        _ ->
          []
      end

    tool_events =
      case delta["tool_calls"] do
        tcs when is_list(tcs) -> Enum.flat_map(tcs, &tool_delta_events/1)
        _ -> []
      end

    completed_events =
      if finish do
        [
          %{
            "type" => "response.completed",
            "response" => %{
              "id" => resp_id,
              "object" => "response",
              "created_at" => System.os_time(:second),
              "status" => convert_finish(finish),
              "model" => model,
              "output" => [],
              "usage" => convert_usage(chunk["usage"])
            }
          }
        ]
      else
        []
      end

    {created_events ++ text_events ++ tool_events ++ completed_events, state}
  end

  # First tool delta carries id+name; subsequent ones carry argument fragments.
  defp tool_delta_events(%{"id" => id, "function" => %{"name" => name}}) do
    [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{"type" => "function_call", "call_id" => id, "name" => name, "arguments" => ""}
      }
    ]
  end

  defp tool_delta_events(%{"function" => %{"arguments" => args}}) when is_binary(args) do
    [%{"type" => "response.function_call_arguments.delta", "output_index" => 0, "delta" => args}]
  end

  defp tool_delta_events(_other), do: []

  # ── Outbound: chat/completions response → Responses API format ──────

  @doc """
  Convert an OpenAI chat/completions response to Responses API format.
  """
  def from_canonical(body) when is_map(body) do
    choice = List.first(body["choices"] || []) || %{}
    message = choice["message"] || %{}

    output = build_output(message)
    status = convert_finish(choice["finish_reason"])

    %{
      "id" => body["id"] || "resp_#{random_id()}",
      "object" => "response",
      "created_at" => body["created"] || System.os_time(:second),
      "status" => status,
      "model" => body["model"],
      "output" => output,
      "usage" => convert_usage(body["usage"])
    }
    |> put_gateway_meta(body)
  end

  defp build_output(message) do
    text_items =
      case message["content"] do
        nil ->
          []

        "" ->
          []

        text when is_binary(text) ->
          [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => text}]
            }
          ]

        # chat content blocks
        blocks when is_list(blocks) ->
          text =
            blocks
            |> Enum.filter(&(&1["type"] == "text"))
            |> Enum.map_join("", & &1["text"])

          if text == "" do
            []
          else
            [
              %{
                "type" => "message",
                "role" => "assistant",
                "content" => [%{"type" => "output_text", "text" => text}]
              }
            ]
          end
      end

    call_items =
      (message["tool_calls"] || [])
      |> Enum.map(fn tc ->
        %{
          "type" => "function_call",
          "call_id" => tc["id"],
          "name" => get_in(tc, ["function", "name"]),
          "arguments" => get_in(tc, ["function", "arguments"]) || "{}"
        }
      end)

    text_items ++ call_items
  end

  defp convert_finish("stop"), do: "completed"
  defp convert_finish("tool_calls"), do: "completed"
  defp convert_finish("length"), do: "incomplete"
  defp convert_finish("content_filter"), do: "incomplete"
  defp convert_finish(_), do: "completed"

  defp convert_usage(nil), do: nil

  defp convert_usage(usage) do
    prompt = usage["prompt_tokens"] || 0
    completion = usage["completion_tokens"] || 0

    %{
      "input_tokens" => prompt,
      "output_tokens" => completion,
      "total_tokens" => prompt + completion
    }
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp put_gateway_meta(result, body) do
    case body["_llmgateway"] do
      nil -> result
      meta -> Map.put(result, "_llmgateway", meta)
    end
  end

  defp random_id,
    do: :crypto.strong_rand_bytes(12) |> Base.hex_encode32(case: :lower, padding: false)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
