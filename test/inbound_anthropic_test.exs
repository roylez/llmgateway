defmodule Llmgateway.InboundAnthropicTest do
  use ExUnit.Case, async: true

  alias Llmgateway.Convert.InboundAnthropic

  describe "to_canonical/1 — Anthropic request → OpenAI" do
    test "basic message with system" do
      body = %{
        "model" => "claude-sonnet-4-20250514",
        "system" => "You are helpful",
        "messages" => [
          %{"role" => "user", "content" => "Hello"}
        ],
        "max_tokens" => 100
      }

      result = InboundAnthropic.to_canonical(body)

      assert result["model"] == "claude-sonnet-4-20250514"
      assert result["max_tokens"] == 100

      [system, user] = result["messages"]
      assert system["role"] == "system"
      assert system["content"] == "You are helpful"
      assert user["role"] == "user"
      assert user["content"] == "Hello"
    end

    test "no system message" do
      body = %{
        "model" => "claude",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "max_tokens" => 50
      }

      result = InboundAnthropic.to_canonical(body)
      assert length(result["messages"]) == 1
      assert hd(result["messages"])["role"] == "user"
    end

    test "converts Anthropic tools to OpenAI format" do
      body = %{
        "model" => "claude",
        "messages" => [%{"role" => "user", "content" => "Weather?"}],
        "max_tokens" => 100,
        "tools" => [
          %{
            "name" => "get_weather",
            "description" => "Get weather",
            "input_schema" => %{
              "type" => "object",
              "properties" => %{"city" => %{"type" => "string"}}
            }
          }
        ],
        "tool_choice" => %{"type" => "auto"}
      }

      result = InboundAnthropic.to_canonical(body)

      [tool] = result["tools"]
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "get_weather"
      assert tool["function"]["parameters"]["properties"]["city"]["type"] == "string"
      assert result["tool_choice"] == "auto"
    end

    test "converts tool_choice any to required" do
      body = %{
        "model" => "claude",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "max_tokens" => 100,
        "tools" => [%{"name" => "f", "input_schema" => %{}}],
        "tool_choice" => %{"type" => "any"}
      }

      result = InboundAnthropic.to_canonical(body)
      assert result["tool_choice"] == "required"
    end

    test "converts thinking to reasoning_effort" do
      body = %{
        "model" => "claude",
        "messages" => [%{"role" => "user", "content" => "Think"}],
        "max_tokens" => 100,
        "thinking" => %{"type" => "enabled", "budget_tokens" => 4096}
      }

      result = InboundAnthropic.to_canonical(body)
      assert result["reasoning_effort"] == "high"
    end

    test "converts stop_sequences to stop" do
      body = %{
        "model" => "claude",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "max_tokens" => 100,
        "stop_sequences" => ["END"]
      }

      result = InboundAnthropic.to_canonical(body)
      assert result["stop"] == ["END"]
    end

    test "converts tool_result messages" do
      body = %{
        "model" => "claude",
        "messages" => [
          %{"role" => "user", "content" => "Weather?"},
          %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "tool_use",
                "id" => "tu_1",
                "name" => "get_weather",
                "input" => %{"city" => "Paris"}
              }
            ]
          },
          %{
            "role" => "user",
            "content" => [
              %{"type" => "tool_result", "tool_use_id" => "tu_1", "content" => "Sunny"}
            ]
          }
        ],
        "max_tokens" => 100
      }

      result = InboundAnthropic.to_canonical(body)

      # Assistant message should have tool_calls in OpenAI format
      assistant = Enum.at(result["messages"], 1)
      assert [tc] = assistant["tool_calls"]
      assert tc["id"] == "tu_1"
      assert tc["function"]["name"] == "get_weather"

      # Tool result should be a tool message
      tool_msg = Enum.at(result["messages"], 2)
      assert tool_msg["role"] == "tool"
      assert tool_msg["tool_call_id"] == "tu_1"
      assert tool_msg["content"] == "Sunny"
    end

    test "converts image content blocks" do
      body = %{
        "model" => "claude",
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "What's this?"},
              %{
                "type" => "image",
                "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "abc123"}
              }
            ]
          }
        ],
        "max_tokens" => 100
      }

      result = InboundAnthropic.to_canonical(body)

      [_text, image] = hd(result["messages"])["content"]
      assert image["type"] == "image_url"
      assert image["image_url"]["url"] == "data:image/png;base64,abc123"
    end
  end

  describe "from_canonical/1 — OpenAI response → Anthropic" do
    test "basic text response" do
      openai_resp = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4o-mini",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "Hello!"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      result = InboundAnthropic.from_canonical(openai_resp)

      assert result["type"] == "message"
      assert result["role"] == "assistant"
      assert result["stop_reason"] == "end_turn"
      assert [%{"type" => "text", "text" => "Hello!"}] = result["content"]
      assert result["usage"]["input_tokens"] == 10
      assert result["usage"]["output_tokens"] == 5
    end

    test "tool_calls response" do
      openai_resp = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4o-mini",
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"Paris"})}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 10}
      }

      result = InboundAnthropic.from_canonical(openai_resp)

      assert result["stop_reason"] == "tool_use"
      [tool_block] = result["content"]
      assert tool_block["type"] == "tool_use"
      assert tool_block["name"] == "get_weather"
      assert tool_block["input"] == %{"city" => "Paris"}
    end

    test "cache tokens preserved" do
      openai_resp = %{
        "id" => "chatcmpl-123",
        "model" => "gpt-4o-mini",
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "Hi"}, "finish_reason" => "stop"}
        ],
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 5,
          "prompt_tokens_details" => %{
            "cached_tokens" => 80,
            "cache_creation_tokens" => 20
          }
        }
      }

      result = InboundAnthropic.from_canonical(openai_resp)

      assert result["usage"]["cache_read_input_tokens"] == 80
      assert result["usage"]["cache_creation_input_tokens"] == 20
    end

    test "finish_reason mapping" do
      for {openai, anthropic} <- [
            {"stop", "end_turn"},
            {"length", "max_tokens"},
            {"tool_calls", "tool_use"}
          ] do
        resp = %{
          "choices" => [%{"message" => %{"content" => "x"}, "finish_reason" => openai}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        }

        result = InboundAnthropic.from_canonical(resp)
        assert result["stop_reason"] == anthropic
      end
    end
  end

  describe "chunk_to_anthropic_events/2" do
    test "first chunk with role emits message_start (no eager text block)" do
      chunk = %{
        "id" => "chatcmpl-1",
        "model" => "gpt-4o",
        "choices" => [
          %{"delta" => %{"role" => "assistant", "content" => ""}, "finish_reason" => nil}
        ]
      }

      assert {:ok, events, state} = InboundAnthropic.chunk_to_anthropic_events(chunk)
      types = Enum.map(events, & &1["type"])
      assert "message_start" in types
      # No eager content_block_start — text block opens on first real content
      refute "content_block_start" in types
      refute state[:text_open]
    end

    test "text delta lazily opens text block" do
      chunk = %{
        "choices" => [%{"delta" => %{"content" => "Hello"}, "finish_reason" => nil}]
      }

      assert {:ok, events, state} =
               InboundAnthropic.chunk_to_anthropic_events(chunk, %{started: true})

      types = Enum.map(events, & &1["type"])
      assert "content_block_start" in types
      assert "content_block_delta" in types
      assert state[:text_open]
      assert state[:next_idx] == 1
    end

    test "finish chunk with text block open emits stop events" do
      chunk = %{
        "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
      }

      assert {:ok, events, _state} =
               InboundAnthropic.chunk_to_anthropic_events(chunk, %{started: true, text_open: true, next_idx: 1})

      types = Enum.map(events, & &1["type"])
      assert "content_block_stop" in types
      assert "message_delta" in types
      assert "message_stop" in types
    end

    test "empty delta is skipped" do
      chunk = %{
        "choices" => [%{"delta" => %{}, "finish_reason" => nil}]
      }

      assert {:skip, _state} = InboundAnthropic.chunk_to_anthropic_events(chunk, %{started: true})
    end

    test "reasoning_content becomes thinking block" do
      chunks = [
        %{"id" => "c1", "model" => "m", "choices" => [%{"delta" => %{"role" => "assistant"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{"reasoning_content" => "Let me think"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{"reasoning_content" => " about this"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{"content" => "The answer is 42"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}], "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20}}
      ]

      {all_events, _final_state} =
        Enum.reduce(chunks, {[], %{}}, fn chunk, {evts, st} ->
          case InboundAnthropic.chunk_to_anthropic_events(chunk, st) do
            {:ok, new_evts, new_st} -> {evts ++ new_evts, new_st}
            {:skip, new_st} -> {evts, new_st}
          end
        end)

      block_starts = Enum.filter(all_events, &(&1["type"] == "content_block_start"))
      assert length(block_starts) == 2
      assert hd(block_starts)["content_block"]["type"] == "thinking"
      assert hd(block_starts)["index"] == 0
      assert List.last(block_starts)["content_block"]["type"] == "text"
      assert List.last(block_starts)["index"] == 1

      thinking_deltas = Enum.filter(all_events, fn e ->
        e["type"] == "content_block_delta" && e["delta"]["type"] == "thinking_delta"
      end)
      assert length(thinking_deltas) == 2
      assert Enum.all?(thinking_deltas, &(&1["index"] == 0))
      assert Enum.map_join(thinking_deltas, "", & &1["delta"]["thinking"]) == "Let me think about this"

      # Thinking block closed before text block opens
      event_types = Enum.map(all_events, & &1["type"])
      blocks_with_idx =
        all_events
        |> Enum.with_index()
        |> Enum.filter(fn {e, _} -> e["type"] == "content_block_start" end)

      {think_start, think_pos} =
        Enum.find(blocks_with_idx, fn {e, _} -> e["content_block"]["type"] == "thinking" end)

      {text_start, text_pos} =
        Enum.find(blocks_with_idx, fn {e, _} -> e["content_block"]["type"] == "text" end)

      think_stop_pos = Enum.find_index(event_types, &(&1 == "content_block_stop"))
      assert think_stop_pos > think_pos
      assert think_stop_pos < text_pos
    end

    test "tool-only response: correct indices, no phantom text block" do
      args1 = "{\\\"city\\\":"
      args2 = "\\\"Paris\\\"}"
      args3 = "{\\\"city\\\":\\\"Paris\\\"}"

      chunks = [
        # 1. Role chunk
        %{"id" => "c1", "model" => "m", "choices" => [%{"delta" => %{"role" => "assistant"}, "finish_reason" => nil}]},
        # 2. Tool call start
        %{"choices" => [%{"delta" => %{"tool_calls" => [%{"index" => 0, "id" => "call_1", "function" => %{"name" => "get_weather", "arguments" => ""}}]}, "finish_reason" => nil}]},
        # 3. Tool arg delta
        %{"choices" => [%{"delta" => %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => args1}}]}, "finish_reason" => nil}]},
        # 4. Tool arg delta continued
        %{"choices" => [%{"delta" => %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => args2}}]}, "finish_reason" => nil}]},
        # 5. Finish
        %{"choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}], "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20}}
      ]

      {all_events, _final_state} =
        Enum.reduce(chunks, {[], %{}}, fn chunk, {evts, st} ->
          case InboundAnthropic.chunk_to_anthropic_events(chunk, st) do
            {:ok, new_evts, new_st} -> {evts ++ new_evts, new_st}
            {:skip, new_st} -> {evts, new_st}
          end
        end)

      types = Enum.map(all_events, & &1["type"])
      assert "message_start" in types
      # Text block should never appear
      refute Enum.any?(all_events, fn e ->
        e["type"] == "content_block_start" && e["content_block"]["type"] == "text"
      end)
      refute Enum.any?(all_events, fn e ->
        e["type"] == "content_block_delta" && e["delta"]["type"] == "text_delta"
      end)

      # Tool block at index 0
      tool_starts = Enum.filter(all_events, &(&1["type"] == "content_block_start"))
      assert length(tool_starts) == 1
      assert hd(tool_starts)["index"] == 0
      assert hd(tool_starts)["content_block"]["type"] == "tool_use"
      assert hd(tool_starts)["content_block"]["id"] == "call_1"
      assert hd(tool_starts)["content_block"]["name"] == "get_weather"

      # Arg deltas at index 0
      arg_deltas = Enum.filter(all_events, fn e ->
        e["type"] == "content_block_delta" && e["delta"]["type"] == "input_json_delta"
      end)
      assert length(arg_deltas) == 2
      assert Enum.all?(arg_deltas, &(&1["index"] == 0))
      assert Enum.map_join(arg_deltas, "", & &1["delta"]["partial_json"]) == args3

      # Proper stop sequence
      assert "content_block_stop" in types
      assert "message_delta" in types
      assert "message_stop" in types

      stop_reason_event = Enum.find(all_events, &(&1["type"] == "message_delta"))
      assert stop_reason_event["delta"]["stop_reason"] == "tool_use"
    end

    test "text then tool: indices are distinct, text block closed before tool" do
      tool_args = "{\\\"x\\\":1}"

      chunks = [
        # 1. Role
        %{"id" => "c1", "model" => "m", "choices" => [%{"delta" => %{"role" => "assistant"}, "finish_reason" => nil}]},
        # 2. Text
        %{"choices" => [%{"delta" => %{"content" => "Let me check"}, "finish_reason" => nil}]},
        # 3. Tool start
        %{"choices" => [%{"delta" => %{"tool_calls" => [%{"index" => 0, "id" => "call_1", "function" => %{"name" => "f", "arguments" => ""}}]}, "finish_reason" => nil}]},
        # 4. Tool arg
        %{"choices" => [%{"delta" => %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => tool_args}}]}, "finish_reason" => nil}]},
        # 5. Finish
        %{"choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}], "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 15}}
      ]

      {all_events, _final_state} =
        Enum.reduce(chunks, {[], %{}}, fn chunk, {evts, st} ->
          case InboundAnthropic.chunk_to_anthropic_events(chunk, st) do
            {:ok, new_evts, new_st} -> {evts ++ new_evts, new_st}
            {:skip, new_st} -> {evts, new_st}
          end
        end)

      # Text block at index 0, tool block at index 1
      block_starts = Enum.filter(all_events, &(&1["type"] == "content_block_start"))
      assert length(block_starts) == 2
      assert hd(block_starts)["index"] == 0
      assert hd(block_starts)["content_block"]["type"] == "text"
      assert List.last(block_starts)["index"] == 1
      assert List.last(block_starts)["content_block"]["type"] == "tool_use"

      # Text block stop comes before tool block start
      event_types_with_idx =
        all_events
        |> Enum.with_index()
        |> Enum.map(fn {e, i} -> {e["type"], e["content_block"], i} end)

      {_, _text_cb, text_start_pos} =
        Enum.find(event_types_with_idx, fn {type, cb, _} -> type == "content_block_start" && cb && cb["type"] == "text" end)

      {_, _tool_cb, tool_start_pos} =
        Enum.find(event_types_with_idx, fn {type, cb, _} -> type == "content_block_start" && cb && cb["type"] == "tool_use" end)

      # First content_block_stop should be for text (at index 0) and come before tool start
      first_stop_pos = Enum.find_index(all_events, &(&1["type"] == "content_block_stop"))
      assert first_stop_pos > text_start_pos
      assert first_stop_pos < tool_start_pos

      # Arg deltas at Anthropic index 1 (not 0)
      arg_deltas = Enum.filter(all_events, fn e ->
        e["type"] == "content_block_delta" && e["delta"]["type"] == "input_json_delta"
      end)
      assert Enum.all?(arg_deltas, &(&1["index"] == 1))
    end
  end
  describe "sanitize_args/1" do
    test "strips trailing period after closing brace" do
      args = "{\"key\": \"val\"}\n."
      result = InboundAnthropic.sanitize_args(args)
      assert result == "{\"key\": \"val\"}"
    end

    test "strips trailing tabs and spaces after closing brace" do
      args = "{\"key\": \"val\"}\t\t \n."
      result = InboundAnthropic.sanitize_args(args)
      assert result == "{\"key\": \"val\"}"
    end

    test "does not modify clean JSON" do
      args = "{\"key\": \"val\"}"
      result = InboundAnthropic.sanitize_args(args)
      assert result == args
    end

    test "handles array with trailing junk" do
      args = "[1, 2, 3]."
      result = InboundAnthropic.sanitize_args(args)
      assert result == "[1, 2, 3]"
    end
  end
end
