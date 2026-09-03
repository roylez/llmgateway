defmodule Llmgateway.Provider do
  @moduledoc """
  Executes LLM API calls against a resolved deployment.

  Uses pattern matching on provider type and response shape for dispatch.
  """

  alias Llmgateway.{Convert, Convert.ResponsesAPI, Deployment, Telemetry, Upstream}

  # ── Public API ────────────────────────────────────────────

  @doc """
  Call a deployment with a chat completions body (OpenAI format).
  """
  def call(%Deployment{} = deployment, body, opts \\ []) do
    tel = Telemetry.request_start(deployment, opts)

    result =
      case Upstream.execute(deployment, body, opts) do
        {:ok, %Req.Response{status: _status, body: body}, warnings, is_responses} ->
          canonical =
            if is_responses do
              ResponsesAPI.from_responses(body)
            else
              Convert.to_canonical(deployment, body)
            end

          {:ok, attach_metadata(canonical, deployment, warnings)}

        {:error, error} ->
          {:error, error}
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

  @cooling_types [:rate_limit, :server_error, :transport_error, :timeout]

  def cooling?(%{type: type}), do: type in @cooling_types
  def cooling?(_), do: false

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
end
