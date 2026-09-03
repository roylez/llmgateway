defmodule Llmgateway.Auth do
  @moduledoc """
  Shared upstream request preparation, authentication, and path helpers.

  `prepare_request/3` is the boundary between provider-specific request mutation
  and the common upstream request setup used by `Provider` and `Stream`.
  """

  require Logger

  alias Llmgateway.Deployment

  # Outbound inference requests identify as LiteLLM so upstream providers
  # (OpenRouter, Z.AI, OpenCode, ...) do not display this gateway as an
  # unknown client. GitHub Copilot overrides this below.
  @inference_user_agent "LiteLLM"

  # OpenRouter's App attribution (the Activity "App" column) is driven by
  # HTTP-Referer + X-OpenRouter-Title, not the User-Agent. Attribute OpenRouter
  # inference as LiteLLM only; other providers get the common user-agent.
  @openrouter_site_url "https://litellm.ai"
  @openrouter_app_title "LiteLLM"

  alias Llmgateway.Convert.ResponsesAPI

  @doc """
  Prepare an authenticated request for an upstream deployment.

  The caller supplies the provider-native request body after its request-specific
  mutations. This function resolves the endpoint and converts only `/responses`
  request bodies.
  """
  def prepare_request(%Deployment{} = deployment, provider_body, timeout) do
    base_req =
      Req.new(base_url: deployment.base_url, receive_timeout: timeout, retry: false)
      |> Req.Request.put_header("user-agent", @inference_user_agent)

    case add_headers(base_req, deployment) do
      {:ok, req} ->
        url = request_path(deployment)
        is_responses = url == "/responses"

        request_body =
          if is_responses do
            ResponsesAPI.to_responses(provider_body, allowed_efforts: allowed_efforts(deployment))
          else
            apply_provider_tuning(provider_body, deployment, url)
          end

        {:ok, req, url, request_body, is_responses}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Keep provider-specific request tuning at this shared outbound boundary.
  defp apply_provider_tuning(
         body,
         %Deployment{provider_type: :openrouter} = deployment,
         "/chat/completions"
       ) do
    provider =
      body
      |> Map.get("provider", %{})
      |> Map.put("preferred_max_latency", %{"p50" => 2})

    body
    |> Map.put("provider", provider)
    |> clamp_reasoning_effort(deployment)
  end

  # Chat Completions deployments get the same reasoning_effort clamping as
  # /responses instead of sending an unsupported value upstream.
  defp apply_provider_tuning(body, %Deployment{} = deployment, "/chat/completions") do
    clamp_reasoning_effort(body, deployment)
  end

  defp apply_provider_tuning(body, _deployment, _url), do: body

  defp clamp_reasoning_effort(body, deployment) do
    case {allowed_efforts(deployment), body["reasoning_effort"]} do
      {allowed, effort} when is_list(allowed) and is_binary(effort) ->
        Map.put(body, "reasoning_effort", ResponsesAPI.clamp_effort(effort, allowed))

      _ ->
        body
    end
  end

  # Extract the model's supported reasoning-effort ladder from canonical
  # LLMDB metadata (extra.reasoning_options). Returns nil when unknown so the
  # converter leaves the client's effort untouched.
  defp allowed_efforts(%Deployment{metadata: %{extra: extra}}) when is_map(extra) do
    extra
    |> Map.get("reasoning_options", [])
    |> Enum.find_value(fn
      %{"type" => "effort", "values" => values} when is_list(values) -> values
      _ -> nil
    end)
  end

  defp allowed_efforts(_), do: nil

  @doc """
  Add auth headers to a Req request based on deployment provider type.

  For github_copilot, also overrides the base_url to the dynamic API base
  from the token exchange (e.g. api.business.githubcopilot.com).

  Returns `{:ok, req}` or `{:error, reason}`.
  """
  def add_headers(_req, %Deployment{provider_type: :github_copilot, runtime: nil}),
    do: {:error, :no_auth_server}

  def add_headers(req, %Deployment{provider_type: :github_copilot, runtime: server}) do
    case Llmgateway.Auth.GitHubDevice.get_token(server) do
      {:ok, token} ->
        api_base = Llmgateway.Auth.GitHubDevice.get_api_base(server)

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

  def add_headers(req, %Deployment{provider_type: :openrouter} = d) do
    {:ok,
     req
     |> Req.Request.put_header("authorization", "Bearer #{d.api_key}")
     |> Req.Request.put_header("http-referer", @openrouter_site_url)
     |> Req.Request.put_header("x-openrouter-title", @openrouter_app_title)}
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
  def request_path(%Deployment{provider_type: :github_copilot, runtime: nil}),
    do: "/chat/completions"

  def request_path(%Deployment{provider_type: :github_copilot, runtime: server} = d) do
    Llmgateway.Auth.GitHubDevice.get_model_endpoint(server, d.upstream_model)
  end

  def request_path(%Deployment{path: path}) when is_binary(path), do: path
  def request_path(%Deployment{provider_type: :anthropic}), do: "/v1/messages"
  def request_path(%Deployment{}), do: "/chat/completions"
end
