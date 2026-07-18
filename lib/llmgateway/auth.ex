defmodule Llmgateway.Auth do
  @moduledoc """
  Shared auth and request path helpers for provider dispatch.
  Used by both Provider (non-streaming) and Stream (streaming).
  """

  require Logger

  alias Llmgateway.Deployment

  @doc """
  Add auth headers to a Req request based on deployment provider type.

  For github_copilot, also overrides the base_url to the dynamic API base
  from the token exchange (e.g. api.business.githubcopilot.com).

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
            api_base = Llmgateway.Auth.GitHubDevice.get_api_base(server_name)

            {:ok,
             %{req | url: URI.parse(api_base)}
             |> Req.Request.put_header("authorization", "Bearer #{token}")
             |> Req.Request.put_header("copilot-integration-id", "vscode-chat")
             |> Req.Request.put_header("editor-version", "vscode/1.95.0")
             |> Req.Request.put_header("user-agent", "GithubCopilot/1.155.0")}

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

  @doc "Return the endpoint path for a deployment and its model."
  def request_path(%Deployment{provider_type: :github_copilot} = d) do
    server_name = :"github_device_#{d.provider_name}"

    case Process.whereis(server_name) do
      nil -> "/chat/completions"
      _pid -> Llmgateway.Auth.GitHubDevice.get_model_endpoint(server_name, d.upstream_model)
    end
  end

  def request_path(%Deployment{provider_type: :anthropic}), do: "/v1/messages"
  def request_path(%Deployment{}), do: "/chat/completions"
end
