defmodule Llmgateway.InboundResponsesTest do
  use ExUnit.Case, async: true

  alias Llmgateway.Convert.InboundResponses

  describe "to_canonical/1 — Responses API request → OpenAI chat" do
    test "string input becomes a user message" do
      body = %{"model" => "gpt-5.6-luna", "input" => "Hello"}

      result = InboundResponses.to_canonical(body)

      assert result["model"] == "gpt-5.6-luna"
      assert [%{"role" => "user", "content" => "Hello"}] = result["messages"]
    end

    test "instructions become a leading system message" do
      body = %{
        "model" => "gpt-5.6-luna",
        "instructions" => "You are helpful",
        "input" => "Hi"
      }

      result = InboundResponses.to_canonical(body)

      assert [system, user] = result["messages"]
      assert system == %{"role" => "system", "content" => "You are helpful"}
      assert user["role"] == "user"
    end

    test "max_output_tokens maps to max_tokens and reasoning effort is extracted" do
      body = %{
        "model" => "gpt-5.6-luna",
        "input" => "Hi",
        "max_output_tokens" => 512,
        "reasoning" => %{"effort" => "high"}
      }

      result = InboundResponses.to_canonical(body)

      assert result["max_tokens"] == 512
      assert result["reasoning_effort"] == "high"
    end

    test "typed message items with input_text blocks are flattened to text" do
      body = %{
        "model" => "gpt-5.6-luna",
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "Hello there"}]
          }
        ]
      }

      result = InboundResponses.to_canonical(body)

      assert [%{"role" => "user", "content" => "Hello there"}] = result["messages"]
    end

    test "developer role maps to system" do
      body = %{
        "model" => "m",
        "input" => [%{"role" => "developer", "content" => "be terse"}]
      }

      result = InboundResponses.to_canonical(body)

      assert [%{"role" => "system", "content" => "be terse"}] = result["messages"]
    end

    test "function_call and function_call_output become tool messages" do
      body = %{
        "model" => "m",
        "input" => [
          %{
            "type" => "function_call",
            "call_id" => "call_1",
            "name" => "get_weather",
            "arguments" => ~s({"city":"Perth"})
          },
          %{"type" => "function_call_output", "call_id" => "call_1", "output" => "sunny"}
        ]
      }

      result = InboundResponses.to_canonical(body)

      assert [assistant, tool] = result["messages"]
      assert assistant["role"] == "assistant"

      assert [%{"id" => "call_1", "function" => %{"name" => "get_weather"}}] =
               assistant["tool_calls"]

      assert tool == %{"role" => "tool", "tool_call_id" => "call_1", "content" => "sunny"}
    end

    test "flat function tools are wrapped for chat completions" do
      body = %{
        "model" => "m",
        "input" => "x",
        "tools" => [
          %{"type" => "function", "name" => "f", "description" => "d", "parameters" => %{}}
        ]
      }

      result = InboundResponses.to_canonical(body)

      assert [%{"type" => "function", "function" => %{"name" => "f"}}] = result["tools"]
    end
  end

  describe "from_canonical/1 — OpenAI chat response → Responses API" do
    test "text choice becomes an output message" do
      canonical = %{
        "id" => "chatcmpl-1",
        "model" => "gpt-5.6-luna",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "Hi!"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      result = InboundResponses.from_canonical(canonical)

      assert result["object"] == "response"
      assert result["status"] == "completed"

      assert [%{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Hi!"}]}] =
               result["output"]

      assert result["usage"] == %{
               "input_tokens" => 10,
               "output_tokens" => 5,
               "total_tokens" => 15
             }
    end

    test "tool calls become function_call output items" do
      canonical = %{
        "model" => "m",
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_9",
                  "type" => "function",
                  "function" => %{"name" => "f", "arguments" => "{}"}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      result = InboundResponses.from_canonical(canonical)

      assert [%{"type" => "function_call", "call_id" => "call_9", "name" => "f"}] =
               result["output"]
    end

    test "length finish maps to incomplete status" do
      canonical = %{
        "model" => "m",
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "x"}, "finish_reason" => "length"}
        ]
      }

      assert InboundResponses.from_canonical(canonical)["status"] == "incomplete"
    end
  end

  describe "chunk_to_responses_events/2 — streaming" do
    test "first chunk emits response.created then text deltas" do
      chunk = %{
        "id" => "c1",
        "model" => "gpt-5.6-luna",
        "choices" => [
          %{"delta" => %{"role" => "assistant", "content" => "Hel"}, "finish_reason" => nil}
        ]
      }

      {events, state} = InboundResponses.chunk_to_responses_events(chunk)

      assert [
               %{"type" => "response.created"},
               %{"type" => "response.output_text.delta", "delta" => "Hel"}
             ] =
               events

      assert state[:started]
    end

    test "finish chunk emits response.completed with usage" do
      chunk = %{
        "id" => "c1",
        "model" => "m",
        "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
      }

      {events, _state} = InboundResponses.chunk_to_responses_events(chunk, %{started: true})

      assert [%{"type" => "response.completed", "response" => resp}] = events
      assert resp["status"] == "completed"
      assert resp["usage"]["total_tokens"] == 5
    end
  end
end
