defmodule Llmgateway.Provider do
  @moduledoc """
  Executes LLM API calls against a resolved deployment.

  Uses pattern matching on provider type and response shape for dispatch.
  """

  require Logger

  alias Llmgateway.{Auth, Convert, Convert.ResponsesAPI, Deployment, Telemetry}

  # ── Public API ────────────────────────────────────────────

  @doc """
  Call a deployment with a chat completions body (OpenAI format).
  """
  def call(%Deployment{} = deployment, body, opts \\ []) do
    timeout = opts[:timeout] || 120_000
    tel = Telemetry.request_start(deployment)

    # Convert OpenAI body → provider native format
    {provider_body, warnings} = Convert.to_provider(deployment, body)

    provider_body =
      provider_body
      |> Map.put("model", deployment.upstream_model)
      |> Map.delete("_llmgateway")

    base_req = Req.new(base_url: deployment.base_url, receive_timeout: timeout, retry: false)

    result =
      case Auth.add_headers(base_req, deployment) do
        {:ok, req} ->
          url = Auth.request_path(deployment)

          # Convert to Responses API format if endpoint is /responses
          {request_body, is_responses} =
            if url == "/responses" do
              {ResponsesAPI.to_responses(provider_body), true}
            else
              {provider_body, false}
            end

          req
          |> Req.post(url: url, json: request_body)
          |> handle_response(deployment, warnings, is_responses)

        {:error, reason} ->
          {:error,
           %{
             type: :client_error,
             status: 401,
             message: "Auth failed: #{inspect(reason)}",
             deployment: deployment.name
           }}
      end

    case result do
      {:ok, response} ->
        Telemetry.request_stop(tel, 200, response["usage"])

      {:error, %{status: s}} ->
        Telemetry.request_exception(tel, :error, %{status: s})

      {:error, reason} ->
        Telemetry.request_exception(tel, :error, reason)
    end

    result
  end

  def retryable?(%{type: type})
      when type in [:rate_limit, :server_error, :transport_error, :timeout, :client_error],
      do: true

  def retryable?(_), do: false

  # ── Response handling (pattern match on status) ───────────

  defp handle_response({:ok, %{status: status, body: body}}, deployment, warnings, is_responses)
       when status in 200..299 do
    canonical =
      if is_responses do
        ResponsesAPI.from_responses(body)
      else
        Convert.to_canonical(deployment, body)
      end

    {:ok, attach_metadata(canonical, deployment, warnings)}
  end

  defp handle_response({:ok, %{status: 429, body: body}}, deployment, _warnings, _is_responses) do
    Logger.warning("#{deployment.name}: rate limited")

    {:error,
     %{type: :rate_limit, status: 429, message: error_message(body), deployment: deployment.name}}
  end

  defp handle_response({:ok, %{status: status, body: body}}, deployment, _warnings, _is_responses)
       when status >= 500 do
    Logger.warning("#{deployment.name}: server error #{status}")

    {:error,
     %{
       type: :server_error,
       status: status,
       message: error_message(body),
       deployment: deployment.name
     }}
  end

  defp handle_response({:ok, %{status: status, body: body}}, deployment, _warnings, _is_responses) do
    Logger.warning("#{deployment.name}: client error #{status}")

    {:error,
     %{
       type: :client_error,
       status: status,
       message: error_message(body),
       deployment: deployment.name
     }}
  end

  defp handle_response(
         {:error, %Req.TransportError{reason: reason}},
         deployment,
         _warnings,
         _is_responses
       ) do
    Logger.warning("#{deployment.name}: transport error #{inspect(reason)}")
    {:error, %{type: :transport_error, reason: reason, deployment: deployment.name}}
  end

  defp handle_response({:error, reason}, deployment, _warnings, _is_responses) do
    Logger.warning("#{deployment.name}: #{inspect(reason)}")
    {:error, %{type: :unknown_error, reason: reason, deployment: deployment.name}}
  end

  # ── Helpers ───────────────────────────────────────────────

  defp attach_metadata(body, deployment, warnings) do
    meta = %{
      "deployment" => deployment.name,
      "provider" => Atom.to_string(deployment.provider_type)
    }

    meta =
      case warnings do
        [] -> meta
        ws -> Map.put(meta, "warnings", Enum.map(ws, fn {kind, msg} -> "#{kind}: #{msg}" end))
      end

    Map.put_new(body, "_llmgateway", meta)
  end

  defp error_message(%{"error" => %{"message" => msg}}), do: msg
  defp error_message(%{"error" => msg}) when is_binary(msg), do: msg
  defp error_message(body) when is_binary(body), do: body
  defp error_message(body), do: inspect(body)
end
