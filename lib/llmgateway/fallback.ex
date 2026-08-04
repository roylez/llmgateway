defmodule Llmgateway.Fallback do
  @moduledoc """
  Executes deployments through fallback chains.

  Retryable provider failures and cooling deployments move to the next accessible
  fallback. Non-retryable provider errors stop the chain.
  """

  require Logger

  alias Llmgateway.{Cooldown, Provider, Router, Stream}

  @doc """
  Call the primary deployment, falling back through the chain on retryable errors.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  def call_with_fallback(deployment, fallback_names, body, opts \\ []) do
    if Cooldown.active?(deployment.provider_name, deployment.name) and fallback_names != [] do
      Logger.info("Deployment #{deployment.name} cooling down; skipping to fallbacks")

      walk(
        fallback_names,
        body,
        opts,
        deployment.name,
        [],
        MapSet.new([deployment.name]),
        :provider
      )
    else
      run_primary(deployment, fallback_names, body, opts, :provider)
    end
  end

  @doc """
  Resolve and stream a model through its fallback chain.

  Returns `{:ok, stream, deployment}` or `{:error, reason}`. The optional
  `:executor` test seam must export `call(deployment, body, opts)`.
  """
  def stream(model_name, body, opts \\ []) do
    executor = opts[:executor] || Stream
    mode = {:stream, executor}

    case Router.resolve_model(model_name, key: opts[:key]) do
      {:ok, deployment, fallback_names} ->
        run_primary(deployment, fallback_names, body, opts, mode)

      {:error, :not_found} ->
        {:error, %{type: :not_found}}

      {:error, :forbidden, fallback_names} ->
        walk(fallback_names, body, opts, model_name, [], MapSet.new([model_name]), mode)

      {:error, :forbidden} ->
        {:error, %{type: :forbidden}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_primary(deployment, fallback_names, body, opts, mode) do
    if cooling?(deployment, fallback_names, mode) do
      log_primary_cooling(deployment, mode)

      walk(
        fallback_names,
        body,
        opts,
        deployment.name,
        [{deployment.name, %{type: :cooling}}],
        MapSet.new([deployment.name]),
        mode
      )
    else
      case execute(deployment, body, opts, mode) do
        {:ok, result} ->
          success(result, deployment, deployment.name, [], mode)

        {:error, reason} when is_map(reason) ->
          if Provider.retryable?(reason) and fallback_names != [] do
            log_primary_failure(deployment, reason, fallback_names, opts, mode)
            Cooldown.record_failure(deployment.provider_name, deployment.name)

            walk(
              fallback_names,
              body,
              opts,
              deployment.name,
              [{deployment.name, reason}],
              MapSet.new([deployment.name]),
              mode
            )
          else
            {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp walk([], _body, _opts, _original, errors, _seen, _mode) do
    {:error, %{type: :all_failed, errors: Enum.reverse(errors)}}
  end

  defp walk([name | rest], body, opts, original, errors, seen, mode) do
    case Router.resolve_model(name, key: opts[:key]) do
      {:ok, deployment, nested} ->
        remaining = remaining(rest, nested, name, seen)
        seen = MapSet.put(seen, name)

        if Cooldown.active?(deployment.provider_name, deployment.name) do
          log_cooling(name, opts, mode)
          walk(remaining, body, opts, original, [{name, %{type: :cooling}} | errors], seen, mode)
        else
          log_attempt(name, remaining, opts, mode)

          case execute(deployment, body, opts, mode) do
            {:ok, result} ->
              success(result, deployment, original, errors, mode)

            {:error, reason} when is_map(reason) ->
              if Provider.retryable?(reason) do
                log_fallback_failure(name, reason, remaining, opts, mode)
                Cooldown.record_failure(deployment.provider_name, deployment.name)
                walk(remaining, body, opts, original, [{name, reason} | errors], seen, mode)
              else
                {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, :forbidden, nested} ->
        remaining = remaining(rest, nested, name, seen)
        log_forbidden(name, remaining, opts, mode)

        walk(
          remaining,
          body,
          opts,
          original,
          [{name, %{type: :forbidden}} | errors],
          MapSet.put(seen, name),
          mode
        )

      {:error, reason} ->
        log_inaccessible(name, reason, opts, mode)

        walk(
          rest,
          body,
          opts,
          original,
          [{name, %{type: :inaccessible}} | errors],
          MapSet.put(seen, name),
          mode
        )
    end
  end

  defp cooling?(deployment, fallback_names, :provider),
    do: fallback_names != [] and Cooldown.active?(deployment.provider_name, deployment.name)

  defp cooling?(deployment, _fallback_names, {:stream, _}),
    do: Cooldown.active?(deployment.provider_name, deployment.name)

  defp execute(deployment, body, opts, :provider), do: Provider.call(deployment, body, opts)

  defp execute(deployment, body, opts, {:stream, executor}) do
    executor.call(deployment, body, Keyword.drop(opts, [:executor]))
  end

  defp success(response, _deployment, _original, [], :provider), do: {:ok, response}

  defp success(response, _deployment, original, errors, :provider) do
    depth = length(errors)
    Logger.info("Fallback to #{original} succeeded after #{depth} attempt(s)")

    {:ok,
     response
     |> put_in(["_llmgateway", "fallback_from"], original)
     |> put_in(["_llmgateway", "fallback_depth"], depth)}
  end

  defp success(stream, deployment, _original, _errors, {:stream, _}),
    do: {:ok, stream, deployment}

  defp remaining(rest, nested, current, seen) do
    Enum.uniq(rest ++ nested)
    |> Kernel.--([current])
    |> Enum.reject(&MapSet.member?(seen, &1))
  end

  defp log_primary_cooling(deployment, :provider),
    do: Logger.info("Deployment #{deployment.name} cooling down; skipping to fallbacks")

  defp log_primary_cooling(deployment, {:stream, _}),
    do: Logger.info("Stream deployment #{deployment.name} cooling down; skipping to fallbacks")

  defp log_primary_failure(deployment, reason, _fallback_names, _opts, :provider),
    do:
      Logger.warning(
        "Primary #{deployment.name} failed: #{reason[:message]}. Trying fallbacks..."
      )

  defp log_primary_failure(deployment, reason, fallback_names, opts, {:stream, _}) do
    Logger.warning(
      "rid=#{opts[:rid]} Stream #{deployment.name} failed (reason: #{inspect(reason)}), trying fallbacks: #{inspect(fallback_names)}"
    )
  end

  defp log_cooling(name, _opts, :provider),
    do: Logger.debug("Skipping fallback #{name} (cooling down)")

  defp log_cooling(name, opts, {:stream, _}),
    do: Logger.debug("rid=#{opts[:rid]} Stream skipping fallback #{name} (cooling down)")

  defp log_attempt(_name, _remaining, _opts, :provider), do: :ok

  defp log_attempt(name, remaining, opts, {:stream, _}) do
    Logger.debug(
      "rid=#{opts[:rid]} Stream trying #{name}, remaining chain: #{inspect(remaining)}"
    )
  end

  defp log_fallback_failure(_name, _reason, _remaining, _opts, :provider), do: :ok

  defp log_fallback_failure(name, reason, remaining, opts, {:stream, _}) do
    Logger.warning(
      "rid=#{opts[:rid]} Stream fallback #{name} failed: #{inspect(reason)}, remaining: #{inspect(remaining)}"
    )
  end

  defp log_forbidden(_name, _remaining, _opts, :provider), do: :ok

  defp log_forbidden(name, remaining, opts, {:stream, _}) do
    Logger.warning(
      "rid=#{opts[:rid]} Stream fallback #{name} forbidden, remaining: #{inspect(remaining)}"
    )
  end

  defp log_inaccessible(_name, _reason, _opts, :provider), do: :ok

  defp log_inaccessible(name, reason, opts, {:stream, _}) do
    Logger.warning("rid=#{opts[:rid]} Stream fallback #{name} resolve failed: #{inspect(reason)}")
  end
end
