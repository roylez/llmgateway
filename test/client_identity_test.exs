defmodule Llmgateway.ClientIdentityTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Llmgateway.ClientIdentity

  test "explicit LiteLLM agent metadata takes precedence" do
    conn =
      conn(:post, "/v1/chat/completions", "")
      |> put_req_header("x-litellm-agent-id", "Claude")
      |> Map.put(:body_params, %{
        "stream_options" => %{"include_usage" => true},
        "store" => false,
        "max_completion_tokens" => 512,
        "reasoning_effort" => "high"
      })

    assert ClientIdentity.app(conn) == "Claude"
  end

  test "explicit OMP agent metadata identifies OMP" do
    conn =
      conn(:post, "/v1/chat/completions", "")
      |> put_req_header("x-litellm-agent-id", "OMP")

    assert ClientIdentity.app(conn) == "OMP"
  end

  test "Bun user agent alone remains unknown" do
    conn =
      conn(:post, "/v1/chat/completions", "")
      |> put_req_header("user-agent", "Bun/1.3.14")
      |> Map.put(:body_params, %{
        "stream_options" => %{"include_usage" => true},
        "store" => false,
        "max_completion_tokens" => 512,
        "reasoning_effort" => "high"
      })

    assert ClientIdentity.app(conn) == "unknown"
  end

  test "a blank agent identifier remains unknown" do
    conn =
      conn(:post, "/v1/chat/completions", "")
      |> put_req_header("x-litellm-agent-id", "")

    assert ClientIdentity.app(conn) == "unknown"
  end
end
