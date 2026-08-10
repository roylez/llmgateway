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
      chunk =
        Enum.join([
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

  describe "stream diagnostics" do
    defp deployment do
      %Llmgateway.Deployment{
        name: "test",
        provider_name: "openai-test",
        provider_type: :openai,
        upstream_model: "gpt-test",
        api_key: "k",
        base_url: "https://example.com",
        context: 128_000,
        output_limit: 16_384
      }
    end

    defp chunks(items) do
      Enum.reject(items, &(match?({:stream_stats, _}, &1) or &1 == :done))
    end

    test "empty stop yields zero-content stats and a diagnostics marker" do
      body = """
      data: {"id":"x","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

      data: [DONE]

      """

      items = LlmStream.build_stream(body, deployment(), false, "rid1") |> Enum.to_list()

      assert {:stream_stats, stats} = List.last(items)
      assert stats.text_deltas == 0
      assert stats.thinking_deltas == 0
      assert stats.tool_deltas == 0
      assert stats.finish == "stop"
      assert stats.done == true
      assert stats.synthetic == false
      assert stats.decode_failures == 0
      assert :done in items
    end

    test "synthesizes a stop when the upstream ends without a finish_reason" do
      body = """
      data: {"id":"router-x","choices":[{"index":0,"delta":{"reasoning_content":" returns it). Hmm"}}]}

      data: {"choices":[],"cost":"0"}

      """

      items = LlmStream.build_stream(body, deployment(), false, "rid-synth") |> Enum.to_list()

      # The empty-choices metadata event must not reach clients as a chunk.
      refute Enum.any?(chunks(items), &(&1["choices"] == []))

      [stop, {:stream_stats, stats}] = Enum.take(items, -2)

      assert stop == %{
               "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
             }

      assert stats.finish == nil
      assert stats.synthetic == true
      refute :done in items
    end

    test "upstream [DONE] without a finish_reason still yields a stop chunk" do
      items =
        LlmStream.build_stream("data: [DONE]\n\n", deployment(), false, "rid-done")
        |> Enum.to_list()

      [stop, {:stream_stats, stats}] = Enum.take(items, -2)

      assert get_in(stop, ["choices", Access.at(0), "finish_reason"]) == "stop"
      assert stats.done == true
      assert stats.synthetic == true
    end

    test "text content is counted and forwarded in order" do
      body = """
      data: {"id":"x","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"}}]}

      data: {"id":"x","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":"stop"}]}

      """

      items = LlmStream.build_stream(body, deployment(), false, "rid2") |> Enum.to_list()

      assert {:stream_stats, stats} = List.last(items)
      assert stats.text_deltas == 2
      assert stats.finish == "stop"

      text =
        items
        |> chunks()
        |> Enum.map(fn c -> get_in(c, ["choices", Access.at(0), "delta", "content"]) end)

      assert text == ["Hello", " world"]
    end

    test "responses-format skipped events are tagged for diagnostics" do
      body = """
      data: {"type":"response.created","response":{"id":"r","model":"g","status":"in_progress"}}

      data: {"type":"response.output_text.done","delta":"hello","sequence_number":2,"schema_name":"output_text_done"}

      data: {"type":"response.reasoning_summary_text.delta","delta":"thinking","sequence_number":3,"schema_name":"reasoning_summary_text_delta"}

      data: {"type":"response.completed","response":{"id":"r","model":"g","status":"completed"}}

      """

      items = LlmStream.build_stream(body, deployment(), true, "rid3") |> Enum.to_list()

      assert {:stream_stats, stats} = List.last(items)

      assert stats.skipped == %{
               "response.output_text.done:output_text_done" => 1,
               "response.reasoning_summary_text.delta:reasoning_summary_text_delta" => 1
             }

      # Only the created + completed events forward chunks.
      assert stats.chunks == 2
      assert stats.text_deltas == 0
      assert stats.thinking_deltas == 0
      assert stats.tool_deltas == 0
    end

    test "undecodable SSE lines are counted as failures and dropped" do
      body = """
      data: {not json

      data: {"id":"x","choices":[{"index":0,"delta":{"content":"ok"}}]}

      data: [DONE]

      """

      items = LlmStream.build_stream(body, deployment(), false, "rid4") |> Enum.to_list()

      assert {:stream_stats, stats} = List.last(items)
      assert stats.decode_failures == 1
      assert stats.text_deltas == 1
    end

    test "log_stats warns on empty and reasoning-only streams, not on text" do
      import ExUnit.CaptureLog

      base = %{
        chunks: 1,
        text_deltas: 0,
        thinking_deltas: 0,
        tool_deltas: 0,
        skipped: %{},
        finish: "stop",
        done: true,
        synthetic: false,
        decode_failures: 0,
        bytes: 74,
        tail: "{}"
      }

      for stats <- [base, %{base | thinking_deltas: 2}] do
        output = capture_log(fn -> LlmStream.log_stats(deployment(), "rid9", stats, nil) end)
        assert output =~ "warning", "expected a warning for #{inspect(stats)}"
        assert output =~ "[stream-stats]"
      end

      ok_output =
        capture_log(fn ->
          LlmStream.log_stats(deployment(), "rid9", %{base | text_deltas: 3}, nil)
        end)

      refute ok_output =~ "warning"
    end

    test "tool-calling responses stream is not an empty stop" do
      # A /responses tool call (the gpt-5.6-terra path) must stream tool_calls
      # deltas instead of degrading to an empty finish_reason: stop turn.
      body =
        [
          %{
            "type" => "response.created",
            "response" => %{"id" => "r", "model" => "gpt-5.6-terra", "status" => "in_progress"}
          },
          %{
            "type" => "response.output_item.added",
            "output_index" => 0,
            "item" => %{
              "type" => "function_call",
              "call_id" => "fc_1",
              "name" => "get_weather",
              "arguments" => ""
            }
          },
          %{
            "type" => "response.function_call_arguments.delta",
            "output_index" => 0,
            "delta" => ~s({"city":"Paris"})
          },
          %{
            "type" => "response.completed",
            "response" => %{
              "id" => "r",
              "model" => "gpt-5.6-terra",
              "status" => "completed",
              "output" => [
                %{"type" => "function_call", "call_id" => "fc_1", "name" => "get_weather"}
              ]
            }
          }
        ]
        |> Enum.map_join("\n", &("data: " <> Jason.encode!(&1)))
        |> Kernel.<>("\ndata: [DONE]\n")

      items = LlmStream.build_stream(body, deployment(), true, "rid10") |> Enum.to_list()
      assert {:stream_stats, stats} = List.last(items)

      # forwarded chunks: created + tool_call header + arguments delta + completed
      assert stats.chunks == 4
      assert stats.text_deltas == 0
      assert stats.tool_deltas == 2
      assert stats.finish == "tool_calls"
      assert stats.skipped == %{}

      tool_calls =
        items
        |> chunks()
        |> Enum.flat_map(fn c ->
          get_in(c, ["choices", Access.at(0), "delta", "tool_calls"]) || []
        end)

      assert Enum.map(tool_calls, & &1["function"]["arguments"]) == ["", ~s({"city":"Paris"})]
      [first | _] = tool_calls
      assert first["id"] == "fc_1"
      assert first["function"]["name"] == "get_weather"
    end
  end
end
