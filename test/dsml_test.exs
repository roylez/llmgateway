defmodule Llmgateway.DSMLTest do
  @moduledoc """
  DSML tool-call markup extraction: parser, streaming translation, and
  non-streaming rewrite. See `Llmgateway.Convert.DSML` for the markup grammar.
  """
  use ExUnit.Case, async: true

  alias Llmgateway.Convert.{DSML, InboundAnthropic}
  alias Llmgateway.Stream, as: LlmStream

  describe "extract/1" do
    test "converts a V4.1 block: leading text kept, params typed, trailing text dropped" do
      text = """
      Let me check.

      <｜DSML｜ calls>
      <｜DSML｜ invoke name="get_weather">
      <｜DSML｜ parameter name="city" string="true">Hangzhou</｜DSML｜ parameter>
      <｜DSML｜ parameter name="days" string="false">3</｜DSML｜ parameter>
      </｜DSML｜ invoke>
      </｜DSML｜ calls>
      junk after the block is dropped
      """

      {visible, calls} = DSML.extract(text)

      assert visible == "Let me check."
      assert [%{name: "get_weather", arguments: args}] = calls
      assert Jason.decode!(args) == %{"city" => "Hangzhou", "days" => 3}
    end

    test "converts V3.2 blocks with multiple invokes" do
      text =
        "<｜DSML｜function_calls>" <>
          "<｜DSML｜invoke name=\"now\"></｜DSML｜invoke>" <>
          "<｜DSML｜invoke name=\"calc\">" <>
          "<｜DSML｜parameter name=\"expr\" string=\"false\">[1,2,3]</｜DSML｜parameter>" <>
          "</｜DSML｜invoke>" <>
          "</｜DSML｜function_calls>"

      {visible, calls} = DSML.extract(text)

      assert visible == ""
      assert [%{name: "now", arguments: "{}"}, %{name: "calc", arguments: args}] = calls
      assert Jason.decode!(args) == %{"expr" => [1, 2, 3]}
    end

    test "converts a bare invoke when the model omits the block start" do
      text =
        "Working<｜DSML｜tool_calls><｜DSML｜invoke name=\"f\"></｜DSML｜invoke></｜DSML｜tool_calls>"

      assert {"Working", [%{name: "f", arguments: "{}"}]} = DSML.extract(text)
    end

    test "leaves plain text untouched, including < and partial markers" do
      assert {"a < b and x", []} = DSML.extract("a < b and x")
      # A dangling marker prefix at end of text is dropped, never leaked.
      assert {"a < b and x ", []} = DSML.extract("a < b and x <｜DSML｜")
    end

    test "drops an incomplete invoke and keeps the text before it" do
      text = "prefix<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"f"

      assert {visible, calls} = DSML.extract(text)
      assert visible == "prefix"
      assert calls == []
    end
  end

  describe "enabled?/2" do
    test "requires a deepseek upstream model and tools in the request" do
      deepseek = deployment("deepseek/deepseek-v4.1-flash")
      glm = deployment("glm-5.3-flash")
      tools = %{"tools" => [%{"name" => "f"}]}

      assert DSML.enabled?(deepseek, tools)
      refute DSML.enabled?(deepseek, %{})
      refute DSML.enabled?(glm, tools)
    end
  end

  describe "build_stream/5 DSML translation" do
    test "converts markup split across deltas and rewrites the finish reason" do
      body =
        """
        data: {"id":"c1","choices":[{"index":0,"delta":{"role":"assistant"}}]}

        """ <>
          sse_text("I'll check.\n\n<｜DSML｜ calls>\n") <>
          sse_text("<｜DSML｜ invoke name=\"edit\">\n") <>
          sse_text(
            "<｜DSML｜ parameter name=\"path\" string=\"true\">lib/a.ex</｜DSML｜ parameter>\n"
          ) <>
          sse_text("</｜DSML｜ invoke>\n</｜DSML｜ calls>") <>
          """
          data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

          data: [DONE]

          """

      items =
        LlmStream.build_stream(
          body,
          deployment("deepseek/deepseek-v4.1-flash"),
          false,
          "rid",
          true
        )
        |> Enum.to_list()

      content =
        for %{"choices" => [%{"delta" => %{"content" => c}} | _]} <- items, is_binary(c), do: c

      tool_chunks =
        for %{"choices" => [%{"delta" => %{"tool_calls" => tcs}} | _]} <- items, do: tcs

      assert content == ["I'll check."]

      [[tc]] = tool_chunks
      assert tc["function"]["name"] == "edit"
      assert Jason.decode!(tc["function"]["arguments"]) == %{"path" => "lib/a.ex"}

      finishes =
        for %{"choices" => [%{"finish_reason" => fr} | _]} <- items, is_binary(fr), do: fr

      assert List.last(finishes) == "tool_calls"
      assert match?({:stream_stats, _}, List.last(items))
    end

    test "plain text stream is unchanged when translation is on" do
      body = """
      data: {"id":"c1","choices":[{"index":0,"delta":{"content":"Hello "}}]}

      data: {"id":"c1","choices":[{"index":0,"delta":{"content":"world"}}]}

      data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

      data: [DONE]

      """

      items =
        LlmStream.build_stream(
          body,
          deployment("deepseek/deepseek-v4.1-flash"),
          false,
          "rid",
          true
        )
        |> Enum.to_list()

      content =
        for %{"choices" => [%{"delta" => %{"content" => c}} | _]} <- items, is_binary(c), do: c

      assert Enum.join(content, "") == "Hello world"

      finishes =
        for %{"choices" => [%{"finish_reason" => fr} | _]} <- items, is_binary(fr), do: fr

      assert List.last(finishes) == "stop"
    end

    test "markup passes through untouched when translation is off" do
      body =
        sse_text("<｜DSML｜ calls><｜DSML｜ invoke name=\"f\"></｜DSML｜ invoke></｜DSML｜ calls>") <>
          """
          data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

          data: [DONE]

          """

      items =
        LlmStream.build_stream(body, deployment("glm-5.3-flash"), false, "rid", false)
        |> Enum.to_list()

      content =
        for %{"choices" => [%{"delta" => %{"content" => c}} | _]} <- items, is_binary(c), do: c

      assert Enum.join(content, "") =~ "DSML"
    end
  end

  describe "rewrite_response/1" do
    test "moves markup into structured tool_calls" do
      response = %{
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" =>
                "Checking.\n\n<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"read\">\n<｜DSML｜ parameter name=\"path\" string=\"true\">a.ex</｜DSML｜ parameter>\n</｜DSML｜ invoke>\n</｜DSML｜ calls>"
            },
            "finish_reason" => "stop"
          }
        ]
      }

      rewritten = DSML.rewrite_response(response)
      choice = hd(rewritten["choices"])
      message = choice["message"]

      assert message["content"] == "Checking."
      assert [%{"type" => "function", "function" => fn_} = tc] = message["tool_calls"]
      assert is_binary(tc["id"])
      assert fn_["name"] == "read"
      assert Jason.decode!(fn_["arguments"]) == %{"path" => "a.ex"}
      assert choice["finish_reason"] == "tool_calls"
    end

    test "returns the response unchanged without markup" do
      response = %{
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "plain"},
            "finish_reason" => "stop"
          }
        ]
      }

      assert DSML.rewrite_response(response) == response
    end
  end

  describe "anthropic conversion of translated chunks" do
    test "emitted chunks become tool_use blocks with stop_reason tool_use" do
      body =
        """
        data: {"id":"c1","choices":[{"index":0,"delta":{"role":"assistant"}}]}

        """ <>
          sse_text(
            "<｜DSML｜ calls><｜DSML｜ invoke name=\"edit\"><｜DSML｜ parameter name=\"path\" string=\"true\">a.ex</｜DSML｜ parameter></｜DSML｜ invoke></｜DSML｜ calls>"
          ) <>
          """
          data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

          data: [DONE]

          """

      items =
        LlmStream.build_stream(
          body,
          deployment("deepseek/deepseek-v4.1-flash"),
          false,
          "rid",
          true
        )
        |> Enum.reject(&(&1 == :done or match?({:stream_stats, _}, &1)))
        |> Enum.to_list()

      {events, _state} =
        Enum.reduce(items, {[], %{}}, fn chunk, {evts, st} ->
          case InboundAnthropic.chunk_to_anthropic_events(chunk, st) do
            {:ok, new, st2} -> {evts ++ new, st2}
            {:skip, st2} -> {evts, st2}
          end
        end)

      assert [
               %{"type" => "message_start"},
               %{
                 "type" => "content_block_start",
                 "content_block" => %{"type" => "tool_use", "name" => "edit"}
               }
               | _
             ] = events

      assert Enum.any?(events, fn event ->
               match?(
                 %{"delta" => %{"type" => "input_json_delta", "partial_json" => json}}
                 when is_binary(json),
                 event
               )
             end)

      assert Enum.any?(
               events,
               &match?(
                 %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
                 &1
               )
             )
    end
  end

  defp deployment(model) do
    %Llmgateway.Deployment{
      name: "test",
      provider_name: "test-provider",
      provider_type: :openai,
      upstream_model: model,
      api_key: "k",
      base_url: "https://example.com",
      context: 128_000,
      output_limit: 16_384
    }
  end

  defp sse_text(text) do
    "data: " <>
      Jason.encode!(%{
        "id" => "c1",
        "choices" => [%{"index" => 0, "delta" => %{"content" => text}}]
      }) <> "\n\n"
  end
end
