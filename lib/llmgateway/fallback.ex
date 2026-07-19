defmodule Llmgateway.Fallback do
  @moduledoc """
  Executes a deployment with fallback chain.

  Tries the primary deployment first, then each fallback in sequence.
  A deployment is skipped (not retried) if:
  - The key doesn't have access (treated as a failure, try next)
  - The provider returns a retryable error (5xx, 429, timeout)

  Non-retryable errors (400, 401, 403 from the provider) stop the chain.
  """

  require Logger

  alias Llmgateway.{Provider, Router}

  @doc """
  Call the primary deployment, falling back through the chain on retryable errors.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  def call_with_fallback(deployment, fallback_names, body, opts \\ []) do
    case Provider.call(deployment, body, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} when is_map(reason) ->
        if Provider.retryable?(reason) and fallback_names != [] do
          Logger.warning(
            "Primary #{deployment.name} failed: #{reason[:message]}. Trying fallbacks..."
          )

          try_fallbacks(fallback_names, body, opts, deployment.name, [{deployment.name, reason}])
        else
          {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_fallbacks([], _body, _opts, _original, errors) do
    {:error, %{type: :all_failed, errors: Enum.reverse(errors)}}
  end

  defp try_fallbacks([fb_name | rest], body, opts, original, errors) do
    key = opts[:key]

    case Router.resolve_model(fb_name, key: key) do
      {:ok, fb_deployment, fb_fallbacks} ->
        # Chain: if this fallback fails, try its own fallbacks too
        remaining = Enum.uniq(rest ++ fb_fallbacks) -- [original | Enum.map(errors, &elem(&1, 0))]

        case Provider.call(fb_deployment, body, opts) do
          {:ok, response} ->
            depth = length(errors)
            Logger.info("Fallback to #{fb_name} succeeded after #{depth} attempt(s)")

            response =
              response
              |> put_in(["_llmgateway", "fallback_from"], original)
              |> put_in(["_llmgateway", "fallback_depth"], depth)

            {:ok, response}

          {:error, reason} when is_map(reason) ->
            if Provider.retryable?(reason) do
              try_fallbacks(remaining, body, opts, original, [{fb_name, reason} | errors])
            else
              {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :forbidden, _fallbacks} ->
        # Key can't access this fallback, skip it
        try_fallbacks(rest, body, opts, original, [{fb_name, %{type: :forbidden}} | errors])

      {:error, _reason} ->
        # Model not found or other issue, skip it
        try_fallbacks(rest, body, opts, original, [{fb_name, %{type: :inaccessible}} | errors])
    end
  end
end
