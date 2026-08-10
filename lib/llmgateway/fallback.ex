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
  def call_with_fallback(deployments, fallback_names, body, opts \\ [])

  def call_with_fallback([deployment | _] = deployments, fallback_names, body, opts) do
    seen =
      opts
      |> Keyword.get(:seen, [])
      |> MapSet.new()
      |> MapSet.put(deployment.name)

    run_candidates(
      deployments,
      fallback_names,
      body,
      opts,
      deployment.name,
      [],
      seen,
      {:call, opts[:executor] || Provider}
    )
  end

  def call_with_fallback(deployment, fallback_names, body, opts) do
    call_with_fallback([deployment], fallback_names, body, opts)
  end

  @doc """
  Resolve and stream a model through its deployment and named fallback chain.

  Returns `{:ok, stream, deployment}` or `{:error, reason}`. The optional
  `:executor` test seam must export `call(deployment, body, opts)`.
  """
  def stream(model_name, body, opts \\ []) do
    mode = {:stream, opts[:executor] || Stream}

    case Router.resolve_deployments(model_name, key: opts[:key]) do
      {:ok, deployments, fallback_names} ->
        run_candidates(
          deployments,
          fallback_names,
          body,
          opts,
          model_name,
          [],
          MapSet.new([model_name]),
          mode
        )

      {:error, :not_found} ->
        {:error, %{type: :not_found}}

      {:error, :forbidden, fallback_names} ->
        walk_names(fallback_names, body, opts, model_name, [], MapSet.new([model_name]), mode)

      {:error, :forbidden} ->
        {:error, %{type: :forbidden}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_candidates([], remaining, body, opts, original, errors, seen, mode) do
    walk_names(remaining, body, opts, original, errors, seen, mode)
  end

  defp run_candidates([deployment | rest], remaining, body, opts, original, errors, seen, mode) do
    candidate = identity(deployment)

    if Cooldown.active?(deployment.provider_name, deployment.upstream_model) do
      log_cooling(candidate, opts, mode)

      run_candidates(
        rest,
        remaining,
        body,
        opts,
        original,
        [{deployment.name, %{type: :cooling}} | errors],
        seen,
        mode
      )
    else
      log_attempt(candidate, remaining, opts, mode)

      case execute(deployment, body, opts, mode) do
        {:ok, result} ->
          success(result, deployment, original, errors, mode)

        {:error, reason} when is_map(reason) ->
          if Provider.retryable?(reason) and
               (rest != [] or remaining != [] or match?({:stream, _}, mode)) do
            log_failure(candidate, reason, remaining, opts, mode)
            if Provider.cooling?(reason),
              do: Cooldown.record_failure(deployment.provider_name, deployment.upstream_model)

            run_candidates(
              rest,
              remaining,
              body,
              opts,
              original,
              [{deployment.name, reason} | errors],
              seen,
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

  defp walk_names([], _body, _opts, _original, errors, _seen, _mode) do
    {:error, %{type: :all_failed, errors: Enum.reverse(errors)}}
  end

  defp walk_names([name | rest], body, opts, original, errors, seen, mode) do
    case Router.resolve_deployments(name, key: opts[:key]) do
      {:ok, deployments, nested} ->
        run_candidates(
          deployments,
          remaining(rest, nested, name, seen),
          body,
          opts,
          original,
          errors,
          MapSet.put(seen, name),
          mode
        )

      {:error, :forbidden, nested} ->
        remaining = remaining(rest, nested, name, seen)
        log_forbidden(name, remaining, opts, mode)

        walk_names(
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

        walk_names(
          Enum.reject(rest, &MapSet.member?(seen, &1)),
          body,
          opts,
          original,
          [{name, %{type: :inaccessible}} | errors],
          MapSet.put(seen, name),
          mode
        )
    end
  end

  defp execute(deployment, body, opts, {kind, executor}) when kind in [:call, :stream] do
    executor.call(deployment, body, Keyword.drop(opts, [:executor, :seen]))
  end

  defp success(response, _deployment, _original, [], {:call, _}), do: {:ok, response}

  defp success(response, _deployment, original, errors, {:call, _}) do
    depth = length(errors)

    {:ok,
     Map.update(
       response,
       "_llmgateway",
       %{
         "fallback_from" => original,
         "fallback_depth" => depth
       },
       fn metadata ->
         metadata
         |> Map.put("fallback_from", original)
         |> Map.put("fallback_depth", depth)
       end
     )}
  end

  defp success(stream, deployment, _original, _errors, {:stream, _}),
    do: {:ok, stream, deployment}

  defp identity(deployment), do: {deployment.provider_name, deployment.upstream_model}

  defp remaining(rest, nested, current, seen) do
    (rest ++ nested)
    |> Enum.reject(&(&1 == current or MapSet.member?(seen, &1)))
    |> Enum.uniq()
  end

  defp log_failure(_candidate, _reason, _remaining, _opts, {:call, _}), do: :ok

  defp log_failure(candidate, reason, remaining, opts, {:stream, _}) do
    Logger.warning(
      "rid=#{opts[:rid]} Stream deployment #{inspect(candidate)} failed: #{inspect(reason)}, remaining names: #{inspect(remaining)}"
    )
  end

  defp log_cooling(_candidate, _opts, {:call, _}), do: :ok

  defp log_cooling(candidate, opts, {:stream, _}) do
    Logger.debug(
      "rid=#{opts[:rid]} Stream skipping deployment #{inspect(candidate)} (cooling down)"
    )
  end

  defp log_attempt(_candidate, _remaining, _opts, {:call, _}), do: :ok

  defp log_attempt(candidate, remaining, opts, {:stream, _}) do
    Logger.debug(
      "rid=#{opts[:rid]} Stream trying #{inspect(candidate)}, remaining names: #{inspect(remaining)}"
    )
  end

  defp log_forbidden(_name, _remaining, _opts, {:call, _}), do: :ok

  defp log_forbidden(name, remaining, opts, {:stream, _}) do
    Logger.warning(
      "rid=#{opts[:rid]} Stream fallback #{name} forbidden, remaining: #{inspect(remaining)}"
    )
  end

  defp log_inaccessible(_name, _reason, _opts, {:call, _}), do: :ok

  defp log_inaccessible(name, reason, opts, {:stream, _}) do
    Logger.warning("rid=#{opts[:rid]} Stream fallback #{name} resolve failed: #{inspect(reason)}")
  end
end
