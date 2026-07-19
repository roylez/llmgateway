defmodule Llmgateway.ServerRoutesTest do
  @moduledoc """
  Tests for all stub and discovery routes on the Server plug.
  Covers every route added for LiteLLM/OpenAI compatibility.
  """
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

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

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp assert_501(method, path, body \\ %{"model" => "test", "input" => "test"}) do
    conn = call(method, path, body)
    assert conn.status == 501
    assert json(conn)["error"]["type"] == "not_implemented"
  end

  defp assert_empty_list(method, path) do
    conn = call(method, path)
    assert conn.status == 200
    assert json(conn)["data"] == []
  end

  defp assert_404(method, path) do
    conn = call(method, path)
    assert conn.status == 404
    assert json(conn)["error"]["type"] == "not_found"
  end

  # ── Discovery routes ──────────────────────────────────────

  describe "GET /v1/model/info" do
    test "returns all models with extended info" do
      conn = call(:get, "/v1/model/info")
      assert conn.status == 200
      body = json(conn)
      assert is_list(body["data"])
      [model | _] = body["data"]
      assert Map.has_key?(model, "id")
      assert model["mode"] == "chat"
      assert Map.has_key?(model, "max_tokens")
      assert Map.has_key?(model, "context_window")
    end

    test "works without /v1 prefix" do
      conn = call(:get, "/model/info")
      assert conn.status == 200
    end

    test "works with /v2 prefix" do
      conn = call(:get, "/v2/model/info")
      assert conn.status == 200
    end
  end

  describe "GET /v1/model_group/info" do
    test "returns models grouped by name" do
      conn = call(:get, "/v1/model_group/info")
      assert conn.status == 200
      body = json(conn)
      assert is_list(body["data"])
      [group | _] = body["data"]
      assert Map.has_key?(group, "model_group")
      assert is_list(group["models"])
    end

    test "works without /v1 prefix" do
      conn = call(:get, "/model_group/info")
      assert conn.status == 200
    end
  end

  # ── v2 prefix stripping ───────────────────────────────────

  describe "v2 prefix stripping" do
    test "strips /v2 and matches /models" do
      conn = call(:get, "/v2/models")
      assert conn.status == 200
      assert json(conn)["object"] == "list"
    end

    test "strips /v2 and matches /models/:id" do
      conn = call(:get, "/v2/models/gpt-4o-mini")
      assert conn.status == 200
      assert json(conn)["id"] == "gpt-4o-mini"
    end
  end

  # ── Completions (legacy) ──────────────────────────────────

  describe "POST /v1/completions" do
    test "returns 404 for unknown model" do
      conn = call(:post, "/v1/completions", %{"model" => "nonexistent", "prompt" => "hello"})
      assert conn.status == 404
    end
  end

  # ── Moderations ─────────────────────────────────────────

  describe "POST /v1/moderations" do
    test "returns benign result for string input" do
      conn =
        call(:post, "/v1/moderations", %{
          "input" => "hello world",
          "model" => "text-moderation-stable"
        })

      assert conn.status == 200
      body = json(conn)
      assert String.starts_with?(body["id"], "modr-")
      assert body["model"] == "text-moderation-stable"
      assert length(body["results"]) == 1
      refute hd(body["results"])["flagged"]
    end

    test "returns benign result for list input" do
      conn = call(:post, "/v1/moderations", %{"input" => ["hello", "world"]})
      assert conn.status == 200
      assert length(json(conn)["results"]) == 2
    end
  end

  # ── Token counting ────────────────────────────────────────

  describe "POST /v1/messages/count_tokens" do
    test "estimates tokens for known model" do
      conn =
        call(:post, "/v1/messages/count_tokens", %{
          "model" => "gpt-4o-mini",
          "messages" => [%{"role" => "user", "content" => "Hello world"}]
        })

      assert conn.status == 200
      body = json(conn)
      assert body["input_tokens"] > 0
      assert body["output_tokens"] == 0
    end

    test "returns 404 for unknown model" do
      conn =
        call(:post, "/v1/messages/count_tokens", %{
          "model" => "nonexistent",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert conn.status == 404
    end
  end

  # ── Stub: not-implemented POST routes ────────────────────

  describe "not-implemented POST routes" do
    test "POST /v1/embeddings returns 501", do: assert_501(:post, "/v1/embeddings")
    test "POST /v1/audio/speech returns 501", do: assert_501(:post, "/v1/audio/speech")

    test "POST /v1/audio/transcriptions returns 501",
      do: assert_501(:post, "/v1/audio/transcriptions")

    test "POST /v1/images/generations returns 501",
      do: assert_501(:post, "/v1/images/generations")

    test "POST /v1/images/edits returns 501", do: assert_501(:post, "/v1/images/edits")
    test "POST /v1/rerank returns 501", do: assert_501(:post, "/v1/rerank")
  end

  # ── Stub: collection resources ─────────────────────────────

  describe "files" do
    test "GET /v1/files returns empty list", do: assert_empty_list(:get, "/v1/files")
    test "POST /v1/files returns 501", do: assert_501(:post, "/v1/files")
    test "GET /v1/files/:id returns 404", do: assert_404(:get, "/v1/files/file-abc")

    test "GET /v1/files/:id/content returns 404",
      do: assert_404(:get, "/v1/files/file-abc/content")

    test "DELETE /v1/files/:id returns 404", do: assert_404(:delete, "/v1/files/file-abc")
  end

  describe "batches" do
    test "GET /v1/batches returns empty list", do: assert_empty_list(:get, "/v1/batches")
    test "POST /v1/batches returns 501", do: assert_501(:post, "/v1/batches")
    test "GET /v1/batches/:id returns 404", do: assert_404(:get, "/v1/batches/batch-abc")

    test "POST /v1/batches/:id/cancel returns 404",
      do: assert_404(:post, "/v1/batches/batch-abc/cancel")
  end

  describe "fine_tuning/jobs" do
    test "GET /v1/fine_tuning/jobs returns empty list",
      do: assert_empty_list(:get, "/v1/fine_tuning/jobs")

    test "POST /v1/fine_tuning/jobs returns 501", do: assert_501(:post, "/v1/fine_tuning/jobs")

    test "GET /v1/fine_tuning/jobs/:id returns 404",
      do: assert_404(:get, "/v1/fine_tuning/jobs/job-abc")

    test "POST /v1/fine_tuning/jobs/:id/cancel returns 404",
      do: assert_404(:post, "/v1/fine_tuning/jobs/job-abc/cancel")
  end

  describe "assistants" do
    test "GET /v1/assistants returns empty list", do: assert_empty_list(:get, "/v1/assistants")
    test "POST /v1/assistants returns 501", do: assert_501(:post, "/v1/assistants")
    test "GET /v1/assistants/:id returns 404", do: assert_404(:get, "/v1/assistants/asst-abc")
    test "POST /v1/assistants/:id returns 404", do: assert_404(:post, "/v1/assistants/asst-abc")

    test "DELETE /v1/assistants/:id returns 404",
      do: assert_404(:delete, "/v1/assistants/asst-abc")
  end

  describe "responses" do
    test "GET /v1/responses returns empty list", do: assert_empty_list(:get, "/v1/responses")
    test "POST /v1/responses returns 501", do: assert_501(:post, "/v1/responses")
    test "GET /v1/responses/:id returns 404", do: assert_404(:get, "/v1/responses/resp-abc")

    test "POST /v1/responses/:id/cancel returns 404",
      do: assert_404(:post, "/v1/responses/resp-abc/cancel")

    test "GET /v1/responses/:id/input_items returns 404",
      do: assert_404(:get, "/v1/responses/resp-abc/input_items")

    test "POST /v1/responses/compact returns 501", do: assert_501(:post, "/v1/responses/compact")
  end

  describe "threads" do
    test "GET /v1/threads returns empty list", do: assert_empty_list(:get, "/v1/threads")
    test "POST /v1/threads returns 501", do: assert_501(:post, "/v1/threads")
    test "GET /v1/threads/:id returns 404", do: assert_404(:get, "/v1/threads/thread-abc")
    test "DELETE /v1/threads/:id returns 404", do: assert_404(:delete, "/v1/threads/thread-abc")

    test "GET /v1/threads/:id/messages returns 404",
      do: assert_404(:get, "/v1/threads/thread-abc/messages")

    test "POST /v1/threads/:id/messages returns 404",
      do: assert_404(:post, "/v1/threads/thread-abc/messages")

    test "GET /v1/threads/:id/runs returns 404",
      do: assert_404(:get, "/v1/threads/thread-abc/runs")

    test "POST /v1/threads/:id/runs returns 404",
      do: assert_404(:post, "/v1/threads/thread-abc/runs")

    test "GET /v1/threads/:id/runs/:run_id returns 404",
      do: assert_404(:get, "/v1/threads/thread-abc/runs/run-xyz")
  end

  describe "realtime" do
    test "GET /v1/realtime returns 501", do: assert_501(:get, "/v1/realtime")

    test "GET /v1/realtime/calls returns empty list",
      do: assert_empty_list(:get, "/v1/realtime/calls")

    test "GET /v1/realtime/client_secrets returns empty list",
      do: assert_empty_list(:get, "/v1/realtime/client_secrets")
  end

  # ── Existing routes still work ─────────────────────────────

  describe "existing routes unchanged" do
    test "GET /health" do
      conn = call(:get, "/health")
      assert conn.status == 200
      assert json(conn)["status"] == "ok"
    end

    test "GET /v1/models lists models" do
      conn = call(:get, "/v1/models")
      assert conn.status == 200
      body = json(conn)
      assert body["object"] == "list"
      names = Enum.map(body["data"], & &1["id"])
      assert "gpt-4o-mini" in names
    end

    test "GET /v1/models/:model_id returns model" do
      conn = call(:get, "/v1/models/gpt-4o-mini")
      assert conn.status == 200
      assert json(conn)["id"] == "gpt-4o-mini"
    end
  end
end
