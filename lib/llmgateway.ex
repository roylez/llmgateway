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

    case Router.resolve_model(model, key: key_name) do
      {:ok, deployment, fallbacks} ->
        Fallback.call_with_fallback(deployment, fallbacks, body, opts)

      {:error, :forbidden, fallbacks} ->
        # Primary is forbidden but fallbacks exist — try them
        Fallback.call_with_fallback(nil, [model | fallbacks], body, opts)

      {:error, :not_found} ->
        {:error, %{type: :not_found, message: "Model '#{model}' not found"}}

      {:error, :forbidden} ->
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
end
