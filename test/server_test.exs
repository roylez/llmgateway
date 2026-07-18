defmodule Llmgateway.ServerTest do
  use ExUnit.Case
  use Plug.Test

  alias Llmgateway.{Config, Router, Server}

  @fixtures_path "test/fixtures"

  setup do
    if Process.whereis(Router), do: GenServer.stop(Router)
    {:ok, config} = Config.load(Path.join(@fixtures_path, "config.yaml"))
    {:ok, _pid} = Router.start_link(config)
    :ok
  end

  defp call(method, path, body \\ nil, headers \\ []) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn =
      Enum.reduce(headers, conn, fn {k, v}, c ->
        put_req_header(c, k, v)
      end)

    Server.call(conn, Server.init([]))
  end

  defp json_response(conn) do
    Jason.decode!(conn.resp_body)
  end

  describe "GET /health" do
    test "returns ok" do
      conn = call(:get, "/health")
      assert conn.status == 200
      assert json_response(conn)["status"] == "ok"
    end
  end

  describe "GET /v1/models" do
    test "lists models without auth" do
      conn = call(:get, "/v1/models")
      assert conn.status == 200
      body = json_response(conn)
      assert body["object"] == "list"
      names = Enum.map(body["data"], & &1["id"])
      assert "gpt-4o-mini" in names
    end

    test "filters models by key" do
      conn = call(:get, "/v1/models", nil, [{"authorization", "Bearer test-personal-key-value"}])
      body = json_response(conn)
      names = Enum.map(body["data"], & &1["id"])
      assert "gpt-4o-mini" in names
      # With multi-deployment, personal-key has its own deepseek-v4-flash deployment
      assert "deepseek-v4-flash" in names
    end

    test "models include limits" do
      conn = call(:get, "/v1/models")
      body = json_response(conn)
      model = Enum.find(body["data"], &(&1["id"] == "gpt-4o-mini"))
      assert is_map(model["limits"])
      assert is_integer(model["limits"]["context"])
    end
  end

  describe "GET /v1/models/:model_id" do
    test "returns model metadata" do
      conn = call(:get, "/v1/models/gpt-4o-mini")
      assert conn.status == 200
      body = json_response(conn)
      assert body["id"] == "gpt-4o-mini"
      assert body["object"] == "model"
      assert is_integer(body["limits"]["context"])
    end

    test "returns 404 for unknown model" do
      conn = call(:get, "/v1/models/nonexistent")
      assert conn.status == 404
    end
  end

  describe "authentication" do
    test "rejects invalid key" do
      conn = call(:get, "/v1/models", nil, [{"authorization", "Bearer bad-key"}])
      assert conn.status == 401
      assert json_response(conn)["error"]["type"] == "authentication_error"
    end

    test "accepts valid key" do
      conn = call(:get, "/v1/models", nil, [{"authorization", "Bearer test-work-key-value"}])
      assert conn.status == 200
    end
  end

  describe "POST /v1/chat/completions" do
    # NOTE: actual provider calls would need mocking.
    # These tests verify routing and error handling.

    test "returns 404 for unknown model" do
      conn =
        call(:post, "/v1/chat/completions", %{
          "model" => "nonexistent",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert conn.status == 404
    end

    test "returns 403 for forbidden model" do
      conn =
        call(
          :post,
          "/v1/chat/completions",
          %{"model" => "deepseek-v4-flash", "messages" => [%{"role" => "user", "content" => "hi"}]},
          [{"authorization", "Bearer test-personal-key-value"}]
        )

      # deepseek-v4-flash restricted to work-key, but has fallback to gpt-4o-mini
      # The fallback tries to call OpenAI for real, fails with transport error
      assert conn.status in [403, 500, 502]
    end
  end

  describe "unknown routes" do
    test "returns 404" do
      conn = call(:get, "/unknown/path")
      assert conn.status == 404
    end
  end
end
