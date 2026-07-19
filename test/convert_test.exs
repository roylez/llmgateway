defmodule Llmgateway.ConvertTest do
  use ExUnit.Case, async: true

  alias Llmgateway.Convert.{OpenAIToAnthropic, AnthropicToOpenAI}

  describe "OpenAI → Anthropic request conversion" do
    test "basic chat message" do
      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "user", "content" => "Hello"}
        ],
        "max_tokens" => 100
      }

      {result, warnings} = OpenAIToAnthropic.convert_request(body)

      assert result["messages"] == [%{"role" => "user", "content" => "Hello"}]
      assert result["max_tokens"] == 100
      assert warnings == []
    end

    test "extracts system message to top level" do
      body = %{
        "messages" => [
          %{"role" => "system", "content" => "You are helpful"},
          %{"role" => "user", "content" => "Hi"}
        ]
      }

      {result, _} = OpenAIToAnthropic.convert_request(body)

      assert result["system"] == "You are helpful"
      assert length(result["messages"]) == 1
      assert hd(result["messages"])["role"] == "user"
    end

    test "clamps temperature to 1.0" do
      body = %{"messages" => [%{"role" => "user", "content" => "Hi"}], "temperature" => 1.5}

      {result, _} = OpenAIToAnthropic.convert_request(body)

      assert result["temperature"] == 1.0
    end

    test "converts stop to stop_sequences" do
      body = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "stop" => ["END", "STOP"]
      }

      {result, _} = OpenAIToAnthropic.convert_request(body)

      assert result["stop_sequences"] == ["END", "STOP"]
      refute Map.has_key?(result, "stop")
    end

    test "drops unsupported params with warnings" do
      body = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "presence_penalty" => 0.5,
        "frequency_penalty" => 0.3,
        "logprobs" => true
      }

      {_result, warnings} = OpenAIToAnthropic.convert_request(body)

      dropped = Enum.map(warnings, fn {:dropped, msg} -> msg end)
      assert Enum.any?(dropped, &String.contains?(&1, "presence_penalty"))
      assert Enum.any?(dropped, &String.contains?(&1, "frequency_penalty"))
      assert Enum.any?(dropped, &String.contains?(&1, "logprobs"))
    end

    test "converts reasoning_effort to thinking budget" do
      body = %{
        "messages" => [%{"role" => "user", "content" => "Think hard"}],
        "reasoning_effort" => "high"
      }

      {result, warnings} = OpenAIToAnthropic.convert_request(body)

      assert result["thinking"] == %{"type" => "enabled", "budget_tokens" => 4096}
      assert warnings == []
    end

    test "converts tool definitions" do
      body = %{
        "messages" => [%{"role" => "user", "content" => "Weather?"}],
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "get_weather",
              "description" => "Get weather",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"city" => %{"type" => "string"}}
              }
            }
          }
        ],
        "tool_choice" => "auto"
      }

      {result, _} = OpenAIToAnthropic.convert_request(body)

      [tool] = result["tools"]
      assert tool["name"] == "get_weather"
      assert tool["input_schema"]["properties"]["city"]["type"] == "string"
      assert result["tool_choice"] == %{"type" => "auto"}
    end

    test "converts tool_choice required to any" do
      body = %{
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "tools" => [%{"type" => "function", "function" => %{"name" => "f", "parameters" => %{}}}],
        "tool_choice" => "required"
      }

      {result, _} = OpenAIToAnthropic.convert_request(body)

      assert result["tool_choice"] == %{"type" => "any"}
    end

    test "converts assistant message with tool_calls" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "Weather?"},
          %{
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
          %{"role" => "tool", "tool_call_id" => "call_1", "content" => "Sunny, 22C"}
        ]
      }

      {result, _} = OpenAIToAnthropic.convert_request(body)

      assistant = Enum.at(result["messages"], 1)

      assert [%{"type" => "tool_use", "id" => "call_1", "name" => "get_weather"}] =
               assistant["content"]

      tool_result = Enum.at(result["messages"], 2)
      assert tool_result["role"] == "user"
      assert [%{"type" => "tool_result", "tool_use_id" => "call_1"}] = tool_result["content"]
    end

    test "converts image_url with data URI" do
      body = %{
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => "What's this?"},
              %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,iVBOR"}}
            ]
          }
        ]
      }

      {result, _} = OpenAIToAnthropic.convert_request(body)

      [text_part, image_part] = hd(result["messages"])["content"]
      assert text_part["type"] == "text"
      assert image_part["type"] == "image"
      assert image_part["source"]["type"] == "base64"
      assert image_part["source"]["media_type"] == "image/png"
      assert image_part["source"]["data"] == "iVBOR"
    end
  end

  describe "Anthropic → OpenAI response conversion" do
    test "basic text response" do
      body = %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-20250514",
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      result = AnthropicToOpenAI.convert_response(body)

      assert result["object"] == "chat.completion"
      assert result["model"] == "claude-sonnet-4-20250514"
      assert [choice] = result["choices"]
      assert choice["message"]["content"] == "Hello!"
      assert choice["message"]["role"] == "assistant"
      assert choice["finish_reason"] == "stop"
      assert result["usage"]["prompt_tokens"] == 10
      assert result["usage"]["completion_tokens"] == 5
      assert result["usage"]["total_tokens"] == 15
    end

    test "tool_use response" do
      body = %{
        "id" => "msg_123",
        "role" => "assistant",
        "model" => "claude-sonnet-4-20250514",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "tu_1",
            "name" => "get_weather",
            "input" => %{"city" => "Paris"}
          }
        ],
        "stop_reason" => "tool_use",
        "usage" => %{"input_tokens" => 20, "output_tokens" => 15}
      }

      result = AnthropicToOpenAI.convert_response(body)

      choice = hd(result["choices"])
      assert choice["finish_reason"] == "tool_calls"
      assert choice["message"]["content"] == nil

      [tc] = choice["message"]["tool_calls"]
      assert tc["id"] == "tu_1"
      assert tc["type"] == "function"
      assert tc["function"]["name"] == "get_weather"
      assert tc["function"]["arguments"] == ~s({"city":"Paris"})
    end

    test "cache tokens exposed in usage" do
      body = %{
        "id" => "msg_123",
        "role" => "assistant",
        "model" => "claude-sonnet-4-20250514",
        "content" => [%{"type" => "text", "text" => "Hi"}],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 10,
          "cache_read_input_tokens" => 80,
          "cache_creation_input_tokens" => 20
        }
      }

      result = AnthropicToOpenAI.convert_response(body)

      details = result["usage"]["prompt_tokens_details"]
      assert details["cached_tokens"] == 80
      assert details["cache_creation_tokens"] == 20
    end

    test "stop_reason mapping" do
      for {anthropic, openai} <- [
            {"end_turn", "stop"},
            {"stop_sequence", "stop"},
            {"max_tokens", "length"},
            {"tool_use", "tool_calls"}
          ] do
        body = %{
          "id" => "msg_1",
          "role" => "assistant",
          "model" => "claude",
          "content" => [%{"type" => "text", "text" => "x"}],
          "stop_reason" => anthropic,
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        }

        result = AnthropicToOpenAI.convert_response(body)
        assert hd(result["choices"])["finish_reason"] == openai
      end
    end
  end

  describe "Anthropic → OpenAI stream event conversion" do
    test "message_start event" do
      event = %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_1",
          "model" => "claude-sonnet-4-20250514",
          "role" => "assistant"
        }
      }

      assert {:ok, chunk} = AnthropicToOpenAI.convert_stream_event(event)
      assert chunk["object"] == "chat.completion.chunk"
      assert chunk["model"] == "claude-sonnet-4-20250514"
    end

    test "text delta event" do
      event = %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => "Hello"},
        "index" => 0
      }

      assert {:ok, chunk} = AnthropicToOpenAI.convert_stream_event(event)
      assert hd(chunk["choices"])["delta"]["content"] == "Hello"
    end

    test "tool use start event" do
      event = %{
        "type" => "content_block_start",
        "content_block" => %{"type" => "tool_use", "id" => "tu_1", "name" => "get_weather"},
        "index" => 1
      }

      assert {:ok, chunk} = AnthropicToOpenAI.convert_stream_event(event)
      [tc] = hd(chunk["choices"])["delta"]["tool_calls"]
      assert tc["id"] == "tu_1"
      assert tc["function"]["name"] == "get_weather"
    end

    test "message_stop event is skipped" do
      assert :skip = AnthropicToOpenAI.convert_stream_event(%{"type" => "message_stop"})
    end

    test "ping event is skipped" do
      assert :skip = AnthropicToOpenAI.convert_stream_event(%{"type" => "ping"})
    end
  end
end
