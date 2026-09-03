defmodule Llmgateway.StubRoutes do
  @moduledoc """
  Compatibility stub routes for the OpenAI/LiteLLM surface not implemented by the
  gateway: embeddings, audio, images, rerank, files, batches, fine_tuning/jobs,
  assistants, threads, responses, realtime, and unsupported native probes.

  All return 501 for POST, empty lists for GET, and 404 for GET by ID.
  """
  use Plug.Router

  require Logger

  alias Llmgateway.Responses

  plug(:match)
  plug(:dispatch)

  # ── Stubs: not-implemented POST routes ─────────────────────

  post "/embeddings" do
    Responses.not_implemented(conn)
  end

  post "/audio/speech" do
    Responses.not_implemented(conn)
  end

  post "/audio/transcriptions" do
    Responses.not_implemented(conn)
  end

  post "/images/generations" do
    Responses.not_implemented(conn)
  end

  post "/images/edits" do
    Responses.not_implemented(conn)
  end

  post "/rerank" do
    Responses.not_implemented(conn)
  end

  # ── Stubs: collection resources (list/create/get/delete) ──

  # Files
  get "/files" do
    Responses.empty_list(conn)
  end

  post "/files" do
    Responses.not_implemented(conn)
  end

  get "/files/:id" do
    Responses.send_json(conn, 404, Responses.error_body("File '#{id}' not found", "not_found"))
  end

  get "/files/:id/content" do
    Responses.send_json(conn, 404, Responses.error_body("File '#{id}' not found", "not_found"))
  end

  delete "/files/:id" do
    Responses.send_json(conn, 404, Responses.error_body("File '#{id}' not found", "not_found"))
  end

  # Batches
  get "/batches" do
    Responses.empty_list(conn)
  end

  post "/batches" do
    Responses.not_implemented(conn)
  end

  get "/batches/:id" do
    Responses.send_json(conn, 404, Responses.error_body("Batch '#{id}' not found", "not_found"))
  end

  post "/batches/:id/cancel" do
    Responses.send_json(conn, 404, Responses.error_body("Batch '#{id}' not found", "not_found"))
  end

  # Fine-tuning
  get "/fine_tuning/jobs" do
    Responses.empty_list(conn)
  end

  post "/fine_tuning/jobs" do
    Responses.not_implemented(conn)
  end

  get "/fine_tuning/jobs/:id" do
    Responses.send_json(
      conn,
      404,
      Responses.error_body("Fine-tuning job '#{id}' not found", "not_found")
    )
  end

  post "/fine_tuning/jobs/:id/cancel" do
    Responses.send_json(
      conn,
      404,
      Responses.error_body("Fine-tuning job '#{id}' not found", "not_found")
    )
  end

  # Assistants
  get "/assistants" do
    Responses.empty_list(conn)
  end

  post "/assistants" do
    Responses.not_implemented(conn)
  end

  get "/assistants/:id" do
    Responses.send_json(conn, 404, Responses.error_body("Assistant '#{id}' not found", "not_found"))
  end

  post "/assistants/:id" do
    Responses.send_json(conn, 404, Responses.error_body("Assistant '#{id}' not found", "not_found"))
  end

  delete "/assistants/:id" do
    Responses.send_json(conn, 404, Responses.error_body("Assistant '#{id}' not found", "not_found"))
  end

  # Responses
  get "/responses" do
    Responses.empty_list(conn)
  end

  post "/responses" do
    Responses.not_implemented(conn)
  end

  get "/responses/:id" do
    Responses.send_json(conn, 404, Responses.error_body("Response '#{id}' not found", "not_found"))
  end

  post "/responses/:id/cancel" do
    Responses.send_json(conn, 404, Responses.error_body("Response '#{id}' not found", "not_found"))
  end

  get "/responses/:id/input_items" do
    Responses.send_json(conn, 404, Responses.error_body("Response '#{id}' not found", "not_found"))
  end

  post "/responses/compact" do
    Responses.not_implemented(conn)
  end

  # Threads
  get "/threads" do
    Responses.empty_list(conn)
  end

  post "/threads" do
    Responses.not_implemented(conn)
  end

  get "/threads/:id" do
    Responses.send_json(conn, 404, Responses.error_body("Thread '#{id}' not found", "not_found"))
  end

  delete "/threads/:id" do
    Responses.send_json(conn, 404, Responses.error_body("Thread '#{id}' not found", "not_found"))
  end

  get "/threads/:thread_id/messages" do
    Responses.send_json(
      conn,
      404,
      Responses.error_body("Thread '#{thread_id}' not found", "not_found")
    )
  end

  post "/threads/:thread_id/messages" do
    Responses.send_json(
      conn,
      404,
      Responses.error_body("Thread '#{thread_id}' not found", "not_found")
    )
  end

  get "/threads/:thread_id/runs" do
    Responses.send_json(conn, 404, Responses.error_body("Thread '#{thread_id}' not found", "not_found"))
  end

  post "/threads/:thread_id/runs" do
    Responses.send_json(conn, 404, Responses.error_body("Thread '#{thread_id}' not found", "not_found"))
  end

  get "/threads/:thread_id/runs/:run_id" do
    Responses.send_json(conn, 404, Responses.error_body("Run '#{run_id}' not found", "not_found"))
  end

  # Realtime
  get "/realtime" do
    Responses.not_implemented(conn)
  end

  get "/realtime/calls" do
    Responses.empty_list(conn)
  end

  get "/realtime/client_secrets" do
    Responses.empty_list(conn)
  end

  # ── Unsupported native probes ──────────────────────────────

  get "/api/v1/models" do
    Responses.unsupported_native_probe(conn, "/api/v1/models")
  end

  get "/api/tags" do
    Responses.unsupported_native_probe(conn, "/api/tags")
  end

  get "/props" do
    Responses.unsupported_native_probe(conn, "/props")
  end

  post "/api/show" do
    Responses.unsupported_native_probe(conn, "/api/show")
  end

  # ── Catch-all ─────────────────────────────────────────────

  match _ do
    Logger.warning("404 unmatched route: #{conn.method} #{conn.request_path}")
    Responses.send_json(conn, 404, Responses.error_body("Not found", "not_found"))
  end
end
