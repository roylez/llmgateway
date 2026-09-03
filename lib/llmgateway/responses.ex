defmodule Llmgateway.Responses do
  @moduledoc """
  Shared response-serialization helpers for the HTTP server modules.
  """
  import Plug.Conn

  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  def empty_list(conn), do: send_json(conn, 200, %{"object" => "list", "data" => []})

  def not_implemented(conn),
    do: send_json(conn, 501, error_body("Not implemented", "not_implemented"))

  def unsupported_native_probe(conn, endpoint) do
    send_json(
      conn,
      404,
      error_body("Native endpoint '#{endpoint}' is not supported", "not_found")
    )
  end

  def put_context_header(conn, deployment) do
    if is_integer(deployment.context) do
      conn
      |> put_resp_header("x-context-length", Integer.to_string(deployment.context))
      |> put_resp_header("x-model-name", deployment.upstream_model)
    else
      conn
    end
  end

  def error_body(message, type, details \\ nil) do
    error = %{"message" => message, "type" => type}
    error = if details, do: Map.put(error, "details", details), else: error
    %{"error" => error}
  end

  def format_error(%{message: msg}), do: msg
  def format_error(err) when is_binary(err), do: err
  def format_error(err), do: inspect(err)
end
