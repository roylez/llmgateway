defmodule Llmgateway.Auth do
  @moduledoc """
  Shared auth and request path helpers for provider dispatch.
  Used by both Provider (non-streaming) and Stream (streaming).
  """

  require Logger

  alias Llmgateway.Deployment

  @doc """
  Add auth headers to a Req request based on deployment provider type.

  Returns `{:ok, req}` or `{:error, reason}`.
  """
  def add_headers(req, %Deployment{provider_type: :github_copilot} = d) do
    server_name = :"github_device_#{d.provider_name}"

    case Process.whereis(server_name) do
      nil ->
        {:error, :no_auth_server}

      _pid ->
        case Llmgateway.Auth.GitHubDevice.get_token(server_name) do
          {:ok, token} ->
            {:ok,
             req
             |> Req.Request.put_header("authorization", "Bearer #{token}")
             |> Req.Request.put_header("copilot-integration-id", "vscode-chat")}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def add_headers(req, %Deployment{api_key: nil}), do: {:ok, req}

  def add_headers(req, %Deployment{provider_type: :anthropic, api_key: key}) do
    {:ok,
     req
     |> Req.Request.put_header("x-api-key", key)
     |> Req.Request.put_header("anthropic-version", "2023-06-01")}
  end

  def add_headers(req, %Deployment{api_key: key}) do
    {:ok, Req.Request.put_header(req, "authorization", "Bearer #{key}")}
  end

  @doc "Return the chat completions endpoint path for a deployment."
  def request_path(%Deployment{provider_type: :anthropic}), do: "/v1/messages"
  def request_path(%Deployment{}), do: "/chat/completions"
end
