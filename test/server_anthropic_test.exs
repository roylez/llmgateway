defmodule Llmgateway.ServerAnthropicTest do
  use ExUnit.Case
  use Plug.Test

  alias Llmgateway.{Config, Router, Server}

  @fixtures_path "test/fixtures"

  setup do
    try do
      if pid = Process.whereis(Router), do: GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end

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

  describe "POST /v1/messages" do
    test "returns 404 for unknown model" do
      conn =
        call(:post, "/v1/messages", %{
          "model" => "nonexistent",
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "max_tokens" => 100
        })

      assert conn.status == 404
      body = json_response(conn)
      assert body["type"] == "error"
      assert body["error"]["type"] == "not_found_error"
    end

    test "accepts x-api-key header for auth" do
      conn =
        call(:get, "/v1/models", nil, [{"x-api-key", "test-work-key-value"}])

      assert conn.status == 200
      body = json_response(conn)
      names = Enum.map(body["data"], & &1["id"])
      assert "deepseek-v4-flash" in names
    end

    test "rejects invalid x-api-key" do
      conn =
        call(:get, "/v1/models", nil, [{"x-api-key", "bad-key"}])

      assert conn.status == 401
    end
  end
end
