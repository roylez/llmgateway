defmodule Llmgateway.Auth do
  @moduledoc """
  Shared auth and request path helpers for provider dispatch.
  Used by both Provider (non-streaming) and Stream (streaming).
  """

  require Logger

  alias Llmgateway.Deployment

  @doc "Add auth headers to a Req request based on deployment provider type."
  def add_headers(req, %Deployment{provider_type: :github_copilot} = d) do
    server_name = :"github_device_#{d.provider_name}"

    case Process.whereis(server_name) do
      nil ->
        Logger.warning("#{d.name}: no GitHub auth server running")
        req

      _pid ->
        case Llmgateway.Auth.GitHubDevice.get_token(server_name) do
          {:ok, token} ->
            req
            |> Req.Request.put_header("authorization", "Bearer #{token}")
            |> Req.Request.put_header("copilot-integration-id", "vscode-chat")

          {:error, reason} ->
            Logger.warning("#{d.name}: GitHub auth failed: #{inspect(reason)}")
            req
        end
    end
  end

  def add_headers(req, %Deployment{api_key: nil}), do: req

  def add_headers(req, %Deployment{provider_type: :anthropic, api_key: key}) do
    req
    |> Req.Request.put_header("x-api-key", key)
    |> Req.Request.put_header("anthropic-version", "2023-06-01")
  end

  def add_headers(req, %Deployment{api_key: key}) do
    Req.Request.put_header(req, "authorization", "Bearer #{key}")
  end

  @doc "Return the chat completions endpoint path for a deployment."
  def request_path(%Deployment{provider_type: :anthropic}), do: "/v1/messages"
  def request_path(%Deployment{}), do: "/chat/completions"
end
