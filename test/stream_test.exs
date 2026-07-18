defmodule Llmgateway.StreamTest do
  use ExUnit.Case, async: true

  alias Llmgateway.Stream, as: LlmStream

  describe "parse_sse_lines/1" do
    test "parses data lines from SSE chunk" do
      chunk = """
      data: {"choices":[{"delta":{"content":"Hello"}}]}

      data: {"choices":[{"delta":{"content":" world"}}]}

      """

      lines = LlmStream.parse_sse_lines(chunk)
      assert length(lines) == 2
      assert Enum.at(lines, 0) =~ "Hello"
      assert Enum.at(lines, 1) =~ "world"
    end

    test "ignores non-data lines" do
      chunk = """
      event: message
      data: {"test": true}
      id: 123

      """

      lines = LlmStream.parse_sse_lines(chunk)
      assert length(lines) == 1
      assert hd(lines) =~ "test"
    end

    test "handles [DONE] marker" do
      chunk = "data: [DONE]\n\n"
      lines = LlmStream.parse_sse_lines(chunk)
      assert lines == ["[DONE]"]
    end

    test "handles empty chunk" do
      assert LlmStream.parse_sse_lines("") == []
      assert LlmStream.parse_sse_lines("\n\n") == []
    end

    test "handles multiple events in single chunk" do
      chunk = Enum.join([
        "data: {\"id\":\"1\"}\n\n",
        "data: {\"id\":\"2\"}\n\n",
        "data: {\"id\":\"3\"}\n\n"
      ])

      lines = LlmStream.parse_sse_lines(chunk)
      assert length(lines) == 3
    end
  end

  describe "SSE line decoding with Anthropic conversion" do
    test "converts Anthropic text_delta to OpenAI chunk format" do
      deployment = %Llmgateway.Deployment{
        name: "test",
        provider_name: "anthropic-test",
        provider_type: :anthropic,
        upstream_model: "claude-sonnet-4-20250514",
        api_key: nil,
        base_url: "https://api.anthropic.com",
        context: 200_000,
        output_limit: 8192
      }

      # Simulate what the SSE parser yields
      event = %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => "Hello"},
        "index" => 0
      }

      {:ok, chunk} = Llmgateway.Convert.stream_event_to_canonical(deployment, event)
      assert chunk["object"] == "chat.completion.chunk"
      assert hd(chunk["choices"])["delta"]["content"] == "Hello"
    end

    test "OpenAI events pass through unchanged" do
      deployment = %Llmgateway.Deployment{
        name: "test",
        provider_name: "openai-test",
        provider_type: :openai,
        upstream_model: "gpt-4o-mini",
        api_key: nil,
        base_url: "https://api.openai.com/v1",
        context: 128_000,
        output_limit: 16_384
      }

      event = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion.chunk",
        "choices" => [%{"delta" => %{"content" => "Hi"}, "index" => 0}]
      }

      # OpenAI events pass through wrapped in {:ok, _}
      assert {:ok, ^event} = Llmgateway.Convert.stream_event_to_canonical(deployment, event)
    end
  end
end
