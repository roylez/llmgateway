defmodule Llmgateway.Convert.ResponsesAPITest do
  use ExUnit.Case, async: true

  alias Llmgateway.Convert.ResponsesAPI

  describe "to_responses/1" do
    test "system message becomes instructions" do
      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "system", "content" => "You are helpful."},
          %{"role" => "user", "content" => "Hello"}
        ]
      }

      result = ResponsesAPI.to_responses(body)

      assert result["instructions"] == "You are helpful."
      assert length(result["input"]) == 1
      assert hd(result["input"])["role"] == "user"
    end

    test "multiple system messages joined with newline" do
      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "system", "content" => "You are helpful."},
          %{"role" => "system", "content" => "Be concise."},
          %{"role" => "user", "content" => "Hi"}
        ]
      }

      result = ResponsesAPI.to_responses(body)

      assert result["instructions"] == "You are helpful.\nBe concise."
      assert length(result["input"]) == 1
    end

    test "user and assistant messages become input array" do
      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "user", "content" => "Hello"},
          %{"role" => "assistant", "content" => "Hi there"},
          %{"role" => "user", "content" => "How are you?"}
        ]
      }

      result = ResponsesAPI.to_responses(body)

      assert result["input"] == [
               %{"role" => "user", "content" => "Hello"},
               %{"role" => "assistant", "content" => "Hi there"},
               %{"role" => "user", "content" => "How are you?"}
             ]
    end

    test "max_tokens becomes max_output_tokens" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "max_tokens" => 256
      }

      result = ResponsesAPI.to_responses(body)

      assert result["max_output_tokens"] == 256
    end

    test "max_completion_tokens also becomes max_output_tokens" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "max_completion_tokens" => 512
      }

      result = ResponsesAPI.to_responses(body)

      assert result["max_output_tokens"] == 512
    end

    test "reasoning_effort becomes reasoning object" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Think hard"}],
        "reasoning_effort" => "high"
      }

      result = ResponsesAPI.to_responses(body)

      assert result["reasoning"] == %{"effort" => "high"}
    end

    test "temperature passes through" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "temperature" => 0.7
      }

      result = ResponsesAPI.to_responses(body)

      assert result["temperature"] == 0.7
    end

    test "top_p passes through" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "top_p" => 0.9
      }

      result = ResponsesAPI.to_responses(body)

      assert result["top_p"] == 0.9
    end

    test "stream passes through" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "stream" => true
      }

      result = ResponsesAPI.to_responses(body)

      assert result["stream"] == true
    end

    test "absent optional params are omitted" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hi"}]
      }

      result = ResponsesAPI.to_responses(body)

      refute Map.has_key?(result, "instructions")
      refute Map.has_key?(result, "max_output_tokens")
      refute Map.has_key?(result, "temperature")
      refute Map.has_key?(result, "top_p")
      refute Map.has_key?(result, "stream")
      refute Map.has_key?(result, "reasoning")
    end

    test "no messages still works" do
      body = %{"model" => "gpt-4"}

      result = ResponsesAPI.to_responses(body)

      assert result["model"] == "gpt-4"
      assert result["input"] == []
    end

    test "tool messages become function_call_output items" do
      body = %{
        "model" => "gpt-4",
        "messages" => [
          %{"role" => "user", "content" => "Weather?"},
          %{"role" => "assistant", "content" => "Let me check."},
          %{"role" => "tool", "tool_call_id" => "call_1", "content" => "Sunny, 22C"}
        ]
      }

      result = ResponsesAPI.to_responses(body)

      assert hd(result["input"])["role"] == "user"
      assert Enum.at(result["input"], 1)["role"] == "assistant"
      tool_item = Enum.at(result["input"], 2)
      assert tool_item["type"] == "function_call_output"
      assert tool_item["call_id"] == "call_1"
      assert tool_item["output"] == "Sunny, 22C"
    end

    test "tools are converted to flat format" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "tools" => [
          %{
            "type" => "function",
            "function" => %{
              "name" => "get_weather",
              "description" => "Get weather",
              "parameters" => %{"type" => "object", "properties" => %{}}
            }
          }
        ]
      }

      result = ResponsesAPI.to_responses(body)

      [tool] = result["tools"]
      assert tool["type"] == "function"
      assert tool["name"] == "get_weather"
      assert tool["description"] == "Get weather"
      assert tool["parameters"] == %{"type" => "object", "properties" => %{}}
    end

    test "nil tools are omitted" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hi"}]
      }

      result = ResponsesAPI.to_responses(body)

      refute Map.has_key?(result, "tools")
    end

    test "empty tools list is omitted" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "tools" => []
      }

      result = ResponsesAPI.to_responses(body)

      refute Map.has_key?(result, "tools")
    end

    test "tool_choice passes through as string" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "tool_choice" => "required"
      }

      result = ResponsesAPI.to_responses(body)

      assert result["tool_choice"] == "required"
    end

    test "nil tool_choice is omitted" do
      body = %{
        "model" => "gpt-4",
        "messages" => [%{"role" => "user", "content" => "Hi"}]
      }

      result = ResponsesAPI.to_responses(body)

      refute Map.has_key?(result, "tool_choice")
    end
  end

  describe "from_responses/1" do
    test "completed text response produces correct chat.completion shape" do
      body = %{
        "id" => "resp_123",
        "object" => "response",
        "status" => "completed",
        "model" => "gpt-4",
        "output" => [
          %{
            "type" => "message",
            "content" => [
              %{"type" => "output_text", "text" => "Hello!"}
            ]
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      result = ResponsesAPI.from_responses(body)

      assert result["id"] == "resp_123"
      assert result["object"] == "chat.completion"
      assert result["model"] == "gpt-4"
      assert is_integer(result["created"])

      [choice] = result["choices"]
      assert choice["index"] == 0
      assert choice["message"]["role"] == "assistant"
      assert choice["message"]["content"] == "Hello!"
      assert choice["finish_reason"] == "stop"

      assert result["usage"]["prompt_tokens"] == 10
      assert result["usage"]["completion_tokens"] == 5
      assert result["usage"]["total_tokens"] == 15
    end

    test "completed -> stop finish_reason" do
      body = %{
        "id" => "resp_1",
        "status" => "completed",
        "model" => "gpt-4",
        "output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => "x"}]}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

      result = ResponsesAPI.from_responses(body)

      assert hd(result["choices"])["finish_reason"] == "stop"
    end

    test "incomplete -> length finish_reason" do
      body = %{
        "id" => "resp_2",
        "status" => "incomplete",
        "model" => "gpt-4",
        "output" => [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => "..."}]}],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 100}
      }

      result = ResponsesAPI.from_responses(body)

      assert hd(result["choices"])["finish_reason"] == "length"
    end

    test "failed -> stop finish_reason" do
      body = %{
        "id" => "resp_3",
        "status" => "failed",
        "model" => "gpt-4",
        "output" => [],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 0}
      }

      result = ResponsesAPI.from_responses(body)

      assert hd(result["choices"])["finish_reason"] == "stop"
    end

    test "function_call output items become tool_calls" do
      body = %{
        "id" => "resp_4",
        "status" => "completed",
        "model" => "gpt-4",
        "output" => [
          %{
            "type" => "function_call",
            "name" => "get_weather",
            "arguments" => ~s({"city":"Paris"}),
            "call_id" => "fc_1"
          }
        ],
        "usage" => %{"input_tokens" => 20, "output_tokens" => 15}
      }

      result = ResponsesAPI.from_responses(body)

      choice = hd(result["choices"])
      assert choice["finish_reason"] == "stop"
      assert choice["message"]["content"] == nil

      [tc] = choice["message"]["tool_calls"]
      assert tc["id"] == "fc_1"
      assert tc["type"] == "function"
      assert tc["function"]["name"] == "get_weather"
      assert tc["function"]["arguments"] == ~s({"city":"Paris"})
    end

    test "usage tokens are converted correctly" do
      body = %{
        "id" => "resp_5",
        "status" => "completed",
        "model" => "gpt-4",
        "output" => [],
        "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
      }

      result = ResponsesAPI.from_responses(body)

      assert result["usage"]["prompt_tokens"] == 100
      assert result["usage"]["completion_tokens"] == 50
      assert result["usage"]["total_tokens"] == 150
    end

    test "nil usage returns nil" do
      body = %{
        "id" => "resp_6",
        "status" => "completed",
        "model" => "gpt-4",
        "output" => []
      }

      result = ResponsesAPI.from_responses(body)

      assert result["usage"] == nil
    end

    test "empty output yields nil content and nil tool_calls" do
      body = %{
        "id" => "resp_7",
        "status" => "completed",
        "model" => "gpt-4",
        "output" => [],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
      }

      result = ResponsesAPI.from_responses(body)

      message = hd(result["choices"])["message"]
      assert message["content"] == nil
      refute Map.has_key?(message, "tool_calls")
    end

    test "multiple output text items are concatenated" do
      body = %{
        "id" => "resp_8",
        "status" => "completed",
        "model" => "gpt-4",
        "output" => [
          %{
            "type" => "message",
            "content" => [
              %{"type" => "output_text", "text" => "Hello"},
              %{"type" => "output_text", "text" => " world"}
            ]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 5}
      }

      result = ResponsesAPI.from_responses(body)

      assert hd(result["choices"])["message"]["content"] == "Hello world"
    end

    test "mixed output: text and function calls" do
      body = %{
        "id" => "resp_9",
        "status" => "completed",
        "model" => "gpt-4",
        "output" => [
          %{
            "type" => "message",
            "content" => [
              %{"type" => "output_text", "text" => "Let me look that up."}
            ]
          },
          %{
            "type" => "function_call",
            "name" => "search",
            "arguments" => ~s({"q":"test"}),
            "call_id" => "fc_2"
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      result = ResponsesAPI.from_responses(body)

      choice = hd(result["choices"])
      assert choice["message"]["content"] == "Let me look that up."

      [tc] = choice["message"]["tool_calls"]
      assert tc["function"]["name"] == "search"
    end
  end

  describe "stream_event_to_chunk/1" do
    test "response.created with response key returns role delta" do
      event = %{
        "type" => "response.created",
        "response" => %{
          "id" => "resp_1",
          "model" => "gpt-4"
        }
      }

      assert {:ok, chunk} = ResponsesAPI.stream_event_to_chunk(event)
      assert chunk["object"] == "chat.completion.chunk"
      assert chunk["id"] == "resp_1"
      assert chunk["model"] == "gpt-4"

      [choice] = chunk["choices"]
      assert choice["delta"]["role"] == "assistant"
      assert choice["delta"]["content"] == ""
      assert choice["finish_reason"] == nil
    end

    test "response.created without response key is skipped" do
      event = %{"type" => "response.created"}

      assert :skip = ResponsesAPI.stream_event_to_chunk(event)
    end

    test "response.output_text.delta returns content delta" do
      event = %{
        "type" => "response.output_text.delta",
        "delta" => "Hello"
      }

      assert {:ok, chunk} = ResponsesAPI.stream_event_to_chunk(event)
      assert chunk["object"] == "chat.completion.chunk"
      assert hd(chunk["choices"])["delta"]["content"] == "Hello"
      assert hd(chunk["choices"])["finish_reason"] == nil
    end

    test "response.content_part.delta with string delta returns content delta" do
      event = %{
        "type" => "response.content_part.delta",
        "delta" => "world"
      }

      assert {:ok, chunk} = ResponsesAPI.stream_event_to_chunk(event)
      assert hd(chunk["choices"])["delta"]["content"] == "world"
    end

    test "response.content_part.delta with non-string delta is skipped" do
      event = %{
        "type" => "response.content_part.delta",
        "delta" => %{"type" => "something_else"}
      }

      assert :skip = ResponsesAPI.stream_event_to_chunk(event)
    end

    test "response.completed returns finish chunk with usage" do
      event = %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_1",
          "model" => "gpt-4",
          "status" => "completed",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }
      }

      assert {:ok, chunk} = ResponsesAPI.stream_event_to_chunk(event)
      assert chunk["object"] == "chat.completion.chunk"

      [choice] = chunk["choices"]
      assert choice["delta"] == %{}
      assert choice["finish_reason"] == "stop"

      assert chunk["usage"]["prompt_tokens"] == 10
      assert chunk["usage"]["completion_tokens"] == 5
      assert chunk["usage"]["total_tokens"] == 15
    end

    test "response.completed with incomplete status returns length finish_reason" do
      event = %{
        "type" => "response.completed",
        "response" => %{
          "status" => "incomplete",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 100}
        }
      }

      assert {:ok, chunk} = ResponsesAPI.stream_event_to_chunk(event)
      assert hd(chunk["choices"])["finish_reason"] == "length"
    end

    test "response.output_text.done is skipped" do
      assert :skip =
               ResponsesAPI.stream_event_to_chunk(%{"type" => "response.output_text.done"})
    end

    test "response.output_item.added is skipped" do
      assert :skip =
               ResponsesAPI.stream_event_to_chunk(%{"type" => "response.output_item.added"})
    end

    test "response.output_item.done is skipped" do
      assert :skip =
               ResponsesAPI.stream_event_to_chunk(%{"type" => "response.output_item.done"})
    end

    test "response.content_part.added is skipped" do
      assert :skip =
               ResponsesAPI.stream_event_to_chunk(%{"type" => "response.content_part.added"})
    end

    test "response.content_part.done is skipped" do
      assert :skip =
               ResponsesAPI.stream_event_to_chunk(%{"type" => "response.content_part.done"})
    end

    test "response.in_progress is skipped" do
      assert :skip =
               ResponsesAPI.stream_event_to_chunk(%{"type" => "response.in_progress"})
    end

    test "unknown event type is skipped" do
      assert :skip = ResponsesAPI.stream_event_to_chunk(%{"type" => "some.unknown.event"})
    end

    test "empty map is skipped" do
      assert :skip = ResponsesAPI.stream_event_to_chunk(%{})
    end
  end
end
