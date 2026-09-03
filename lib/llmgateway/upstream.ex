defmodule Llmgateway.Upstream do
  @moduledoc """
  Consolidated outbound request construction shared by `Provider` and `Stream`.

  Owns canonical-to-provider body preparation, model/stream flag injection, auth
  prep, Req execution, and HTTP status/transport error classification. Callers
  keep their response-specific work: `Provider` decodes buffered responses and
  attaches metadata, `Stream` parses SSE and tracks diagnostics.

  `execute/3` returns `{:ok, %Req.Response{}, warnings, is_responses}` on a 2xx
  response so the caller can finish decoding, or `{:error, classified}` when the
  request could not produce a usable 2xx body.
  """

  require Logger

  alias Llmgateway.{Auth, Convert, Deployment}

  @doc """
  Run a request against `deployment` with a canonical (OpenAI-format) `body`.

  `opts` may contain `:timeout` and `:rid`; set `:stream` to select Req's
  `into: :self` so `Stream` can parse SSE line by line.
  """
  def execute(%Deployment{} = deployment, body, opts) do
    timeout = opts[:timeout] || 120_000
    stream? = opts[:stream] || false
    rid = opts[:rid]

    {provider_body, warnings} = prepare_body(deployment, body, stream?)

    case Auth.prepare_request(deployment, provider_body, timeout) do
      {:ok, req, url, request_body, is_responses} ->
        if stream? do
          Logger.debug(
            "[stream] rid=#{rid || "-"} send url=#{url} model=#{deployment.upstream_model}"
          )
        end

        result = run(req, url, request_body, stream?)
        handle_result(result, deployment, warnings, is_responses, stream?)

      {:error, reason} ->
        {:error,
         %{
           type: :client_error,
           status: 401,
           message: "Auth failed: #{inspect(reason)}",
           deployment: deployment.name
         }}
    end
  end

  # ── Body preparation ──────────────────────────────────────

  defp prepare_body(%Deployment{} = deployment, body, stream?) do
    {provider_body, warnings} = Convert.to_provider(deployment, body)

    provider_body =
      provider_body
      |> Map.put("model", deployment.upstream_model)
      |> maybe_put_stream(stream?)
      |> Map.delete("_llmgateway")

    {provider_body, warnings}
  end

  defp maybe_put_stream(body, true), do: Map.put(body, "stream", true)
  defp maybe_put_stream(body, false), do: body

  # ── Req execution ─────────────────────────────────────────

  defp run(req, url, request_body, true),
    do: Req.post(req, url: url, json: request_body, into: :self)

  defp run(req, url, request_body, false),
    do: Req.post(req, url: url, json: request_body)

  # ── HTTP status / transport error classification ─────────
  #
  # Buffered (non-stream) responses arrive as a decoded map/binary; streamed
  # responses carry the raw SSE as an async body that must be drained. Preserve
  # each path's original error message exactly.

  defp handle_result(
         {:ok, %Req.Response{status: status} = resp},
         _deployment,
         warnings,
         is_responses,
         _stream?
       )
       when status in 200..299 do
    {:ok, resp, warnings, is_responses}
  end

  defp handle_result(
         {:ok, %Req.Response{status: 429, body: body}},
         deployment,
         _warnings,
         _is_responses,
         stream?
       ) do
    warn(deployment, "rate limited")

    {:error,
     %{
       type: :rate_limit,
       status: 429,
       message: error_message(body, stream?),
       deployment: deployment.name
     }}
  end

  defp handle_result(
         {:ok, %Req.Response{status: status, body: body}},
         deployment,
         _warnings,
         _is_responses,
         stream?
       )
       when status >= 500 do
    warn(deployment, "server error #{status}")

    {:error,
     %{
       type: :server_error,
       status: status,
       message: error_message(body, stream?),
       deployment: deployment.name
     }}
  end

  defp handle_result(
         {:ok, %Req.Response{status: status, body: body}},
         deployment,
         _warnings,
         _is_responses,
         stream?
       ) do
    warn(deployment, "client error #{status}")

    {:error,
     %{
       type: :client_error,
       status: status,
       message: error_message(body, stream?),
       deployment: deployment.name
     }}
  end

  defp handle_result(
         {:error, %Req.TransportError{reason: reason}},
         deployment,
         _warnings,
         _is_responses,
         _stream?
       ) do
    warn(deployment, "transport error #{inspect(reason)}")
    {:error, %{type: :transport_error, reason: reason, deployment: deployment.name}}
  end

  defp handle_result({:error, reason}, deployment, _warnings, _is_responses, _stream?) do
    warn(deployment, inspect(reason))
    {:error, %{type: :unknown_error, reason: reason, deployment: deployment.name}}
  end

  # ── Helpers ───────────────────────────────────────────────

  defp warn(deployment, msg) do
    Logger.warning(
      "#{deployment.name}: #{msg} (provider=#{deployment.provider_type}, upstream=#{deployment.upstream_model})"
    )
  end

  # Buffered (provider) error bodies keep their pre-existing semantics: the
  # provider's `error.message`, else the full binary, else an inspect of the
  # decoded map. Streamed bodies are drained to a string and sliced to 500 to
  # match `Stream.classify_error`'s bounded message.
  defp error_message(body, false) when is_binary(body), do: body
  defp error_message(%{"error" => %{"message" => msg}}, _stream?), do: msg
  defp error_message(%{"error" => msg}, _stream?) when is_binary(msg), do: msg
  defp error_message(body, false) when is_map(body), do: inspect(body)
  defp error_message(body, true) when is_binary(body), do: slice(body)
  defp error_message(body, true), do: slice(drain_to_string(body))

  defp slice(s), do: String.slice(s, 0, 500)

  defp drain_to_string(body) when is_binary(body), do: body

  defp drain_to_string(body) do
    try do
      Enum.join(body, "")
    rescue
      _ -> ""
    end
  end
end
