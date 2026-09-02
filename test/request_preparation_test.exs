defmodule Llmgateway.RequestPreparationTest.CapturePlug do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)

    headers =
      for {name, value} <- conn.req_headers, into: %{} do
        {name, value}
      end

    send(opts[:owner], {:captured_request, conn.request_path, headers, Jason.decode!(body)})

    response =
      if conn.request_path == "/responses" do
        Jason.encode!(%{
          "id" => "response-1",
          "model" => "test-model",
          "status" => "completed",
          "output" => [
            %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "ok"}]}
          ],
          "usage" => %{}
        })
      else
        Jason.encode!(%{
          "id" => "chatcmpl-1",
          "object" => "chat.completion",
          "model" => "test-model",
          "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}}],
          "usage" => %{}
        })
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, response)
  end
end

defmodule Llmgateway.RequestPreparationTest do
  use ExUnit.Case

  alias Llmgateway.{Deployment, Provider, Stream}
  alias Llmgateway.Auth

  setup do
    {:ok, server} =
      Bandit.start_link(
        plug: {Llmgateway.RequestPreparationTest.CapturePlug, owner: self()},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    %{
      base_url: "http://127.0.0.1:#{port}",
      body: %{
        "messages" => [
          %{"role" => "system", "content" => "You are helpful."},
          %{"role" => "user", "content" => "Hello"}
        ]
      }
    }
  end

  test "Provider.call converts only responses request bodies", %{base_url: base_url, body: body} do
    assert {:ok, _response} = Provider.call(deployment(base_url, "/responses"), body)

    assert_receive {:captured_request, "/responses", _headers, responses_body}
    assert responses_body["input"] == [%{"role" => "user", "content" => "Hello"}]
    assert responses_body["instructions"] == "You are helpful."
    refute Map.has_key?(responses_body, "messages")

    assert {:ok, _response} = Provider.call(deployment(base_url, "/chat/completions"), body)

    assert_receive {:captured_request, "/chat/completions", _headers, chat_body}
    assert chat_body["messages"] == body["messages"]
    refute Map.has_key?(chat_body, "input")
    refute Map.has_key?(chat_body, "provider")
  end

  test "Provider.call applies the OpenRouter latency policy", %{base_url: base_url, body: body} do
    body =
      Map.put(body, "provider", %{
        "order" => ["test-provider"],
        "preferred_max_latency" => %{"p50" => 10}
      })

    assert {:ok, _response} =
             Provider.call(deployment(base_url, "/chat/completions", :openrouter), body)

    assert_receive {:captured_request, "/chat/completions", headers, chat_body}
    assert headers["user-agent"] == "LiteLLM"
    assert headers["x-openrouter-title"] == "LiteLLM"
    assert headers["http-referer"] == "https://litellm.ai"
    assert chat_body["messages"] == body["messages"]
    assert chat_body["model"] == "test-model"

    assert chat_body["provider"] == %{
             "order" => ["test-provider"],
             "preferred_max_latency" => %{"p50" => 2}
           }

    refute Map.has_key?(chat_body, "input")
  end

  test "Provider.call sends LiteLLM user-agent to generic providers", %{
    base_url: base_url,
    body: body
  } do
    assert {:ok, _response} = Provider.call(deployment(base_url, "/chat/completions"), body)

    assert_receive {:captured_request, "/chat/completions", headers, chat_body}
    assert headers["user-agent"] == "LiteLLM"
    refute Map.has_key?(headers, "x-openrouter-title")
    refute Map.has_key?(headers, "http-referer")
    assert chat_body["messages"] == body["messages"]
    refute Map.has_key?(chat_body, "provider")
  end

  test "Stream.call converts only responses request bodies", %{base_url: base_url, body: body} do
    assert {:ok, _stream} = Stream.call(deployment(base_url, "/responses"), body)

    assert_receive {:captured_request, "/responses", _headers, responses_body}
    assert responses_body["input"] == [%{"role" => "user", "content" => "Hello"}]
    assert responses_body["stream"] == true
    refute Map.has_key?(responses_body, "messages")

    assert {:ok, _stream} = Stream.call(deployment(base_url, "/chat/completions"), body)

    assert_receive {:captured_request, "/chat/completions", _headers, chat_body}
    assert chat_body["messages"] == body["messages"]
    assert chat_body["stream"] == true
    refute Map.has_key?(chat_body, "input")
    refute Map.has_key?(chat_body, "provider")
  end

  test "Stream.call converts image content for Responses API", %{base_url: base_url} do
    body = %{
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "Describe the image."},
            %{"type" => "image_url", "image_url" => %{"url" => "https://example.test/image.png"}}
          ]
        }
      ]
    }

    assert {:ok, _stream} = Stream.call(deployment(base_url, "/responses"), body)

    assert_receive {:captured_request, "/responses", _headers, responses_body}

    assert responses_body["input"] == [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "Describe the image."},
                 %{"type" => "input_image", "image_url" => "https://example.test/image.png"}
               ]
             }
           ]
  end

  test "Stream.call injects OpenRouter preferred_max_latency into chat completions", %{
    base_url: base_url,
    body: body
  } do
    assert {:ok, _stream} =
             Stream.call(deployment(base_url, "/chat/completions", :openrouter), body)

    assert_receive {:captured_request, "/chat/completions", headers, chat_body}
    assert headers["user-agent"] == "LiteLLM"
    assert headers["x-openrouter-title"] == "LiteLLM"
    assert headers["http-referer"] == "https://litellm.ai"
    assert chat_body["messages"] == body["messages"]
    assert chat_body["model"] == "test-model"
    assert chat_body["stream"] == true
    assert chat_body["provider"] == %{"preferred_max_latency" => %{"p50" => 2}}
    refute Map.has_key?(chat_body, "input")
  end

  test "Auth.prepare_request clamps chat completions reasoning_effort to the model's ladder", %{
    base_url: base_url
  } do
    deployment = %{
      deployment(base_url, "/chat/completions")
      | metadata: %{
          extra: %{
            "reasoning_options" => [%{"type" => "effort", "values" => ["low", "high", "max"]}]
          }
        }
    }

    # "xhigh" is unsupported by kimi-k3: it clamps to the nearest supported
    # level. It sits between "high" and "max"; ties resolve upward, so "max".
    body = %{
      "model" => "kimi-k3",
      "messages" => [%{"role" => "user", "content" => "Hello"}],
      "reasoning_effort" => "xhigh"
    }

    assert {:ok, _req, "/chat/completions", request_body, false} =
             Auth.prepare_request(deployment, body, 30_000)

    assert request_body["reasoning_effort"] == "max"

    # Supported values pass through unchanged.
    for effort <- ["low", "high", "max"] do
      assert {:ok, _req, _url, request_body, false} =
               Auth.prepare_request(deployment, %{body | "reasoning_effort" => effort}, 30_000)

      assert request_body["reasoning_effort"] == effort
    end

    # Unknown metadata leaves the client's effort untouched.
    assert {:ok, _req, _url, request_body, false} =
             Auth.prepare_request(deployment(base_url, "/chat/completions"), body, 30_000)

    assert request_body["reasoning_effort"] == "xhigh"
  end

  defp deployment(base_url, path, provider_type \\ :openai) do
    %Deployment{
      name: "test",
      provider_name: "test-provider",
      provider_type: provider_type,
      upstream_model: "test-model",
      api_key: if(provider_type == :openrouter, do: "openrouter-key"),
      base_url: base_url,
      context: 1,
      output_limit: 1,
      path: path
    }
  end
end
