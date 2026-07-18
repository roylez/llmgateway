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
            "input_schema" => %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}}
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
          %{"role" => "assistant", "content" => [
            %{"type" => "tool_use", "id" => "tu_1", "name" => "get_weather", "input" => %{"city" => "Paris"}}
          ]},
          %{"role" => "user", "content" => [
            %{"type" => "tool_result", "tool_use_id" => "tu_1", "content" => "Sunny"}
          ]}
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
          %{"role" => "user", "content" => [
            %{"type" => "text", "text" => "What's this?"},
            %{"type" => "image", "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "abc123"}}
          ]}
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
                %{"id" => "call_1", "type" => "function", "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"Paris"})}}
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
    test "first chunk with role emits message_start" do
      chunk = %{
        "id" => "chatcmpl-1",
        "model" => "gpt-4o",
        "choices" => [%{"delta" => %{"role" => "assistant", "content" => ""}, "finish_reason" => nil}]
      }

      assert {:ok, events, _state} = InboundAnthropic.chunk_to_anthropic_events(chunk)
      types = Enum.map(events, & &1["type"])
      assert "message_start" in types
      assert "content_block_start" in types
    end

    test "text delta chunk" do
      chunk = %{
        "choices" => [%{"delta" => %{"content" => "Hello"}, "finish_reason" => nil}]
      }

      assert {:ok, [event], _state} = InboundAnthropic.chunk_to_anthropic_events(chunk, %{started: true})
      assert event["type"] == "content_block_delta"
      assert event["delta"]["text"] == "Hello"
    end

    test "finish chunk emits stop events" do
      chunk = %{
        "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
      }

      assert {:ok, events, _state} = InboundAnthropic.chunk_to_anthropic_events(chunk, %{started: true})
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
  end
end
