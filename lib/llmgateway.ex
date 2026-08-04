defmodule Llmgateway do
  @moduledoc """
  LLM Gateway — a proxy for LLM providers.

  Provides a unified OpenAI-compatible API that routes to multiple providers
  with API-style conversion, fallback chains, and key-based access control.

  ## Usage

      # Load config and start the router
      Llmgateway.start("config/config.yaml")

      # Generate text
      {:ok, response} = Llmgateway.generate_text("deepseek-v4-flash", %{
        "messages" => [%{"role" => "user", "content" => "Hello!"}]
      })

      # With key-based access
      {:ok, response} = Llmgateway.generate_text("gpt-4o-mini", %{
        "messages" => [%{"role" => "user", "content" => "Hello!"}]
      }, key: "work-key")
  """

  alias Llmgateway.{Fallback, Router}

  @doc """
  Generate a chat completion.

  `model` is the local model alias (as defined in config.yaml).
  `body` is the request body in OpenAI chat/completions format.
  `opts` may include `:key` for key-based access control.

  Returns `{:ok, response_body}` or `{:error, reason}`.
  """
  def generate_text(model, body, opts \\ []) do
    key_name = opts[:key]

    case Router.resolve_deployments(model, key: key_name) do
      {:ok, deployments, fallbacks} ->
        Fallback.call_with_fallback(deployments, fallbacks, body, opts)

      {:error, :forbidden, fallbacks} ->
        try_fallback_only(fallbacks, body, opts, MapSet.new([model]))

      {:error, :not_found} ->
        {:error, %{type: :not_found, message: "Model '#{model}' not found"}}

      {:error, :forbidden} ->
        {:error, %{type: :forbidden, message: "Key does not have access to model '#{model}'"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stream a chat completion. Returns `{:ok, stream}` where stream yields OpenAI chunks.
  """
  def stream_text(model, body, opts \\ []) do
    case Fallback.stream(model, body, opts) do
      {:ok, stream, _deployment} ->
        {:ok, stream}

      {:error, %{type: :not_found}} ->
        {:error, %{type: :not_found, message: "Model '#{model}' not found"}}

      {:error, %{type: :forbidden}} ->
        {:error, %{type: :forbidden, message: "Key does not have access to model '#{model}'"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List available models, optionally filtered by key.
  """
  def list_models(opts \\ []) do
    Router.list_models(opts)
  end

  @doc """
  Resolve a key token to a key name.
  """
  def resolve_key(token) do
    Router.resolve_key(token)
  end

  defp try_fallback_only([], _body, _opts, _seen) do
    {:error, %{type: :forbidden, message: "No accessible fallbacks"}}
  end

  defp try_fallback_only([fb_name | rest], body, opts, seen) do
    if MapSet.member?(seen, fb_name) do
      try_fallback_only(rest, body, opts, seen)
    else
      seen = MapSet.put(seen, fb_name)

      case Router.resolve_deployments(fb_name, key: opts[:key]) do
        {:ok, deployments, more_fallbacks} ->
          Fallback.call_with_fallback(
            deployments,
            rest ++ more_fallbacks,
            body,
            Keyword.put(opts, :seen, seen)
          )

        {:error, :forbidden, nested} ->
          try_fallback_only(rest ++ nested, body, opts, seen)

        {:error, _} ->
          try_fallback_only(rest, body, opts, seen)
      end
    end
  end
end
