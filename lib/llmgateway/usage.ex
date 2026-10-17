defmodule Llmgateway.Usage do
  @moduledoc """
  Records token usage for successful requests and queries it back.

  Recording never raises into the request path: a failed insert is logged
  and dropped.
  """

  require Logger
  import Ecto.Query

  alias Llmgateway.{Repo, Usage.Entry}

  @default_limit 100

  @doc """
  Store one successful request. `usage` is the upstream usage map, or nil
  when the upstream sent none.
  """
  def record(deployment, usage, opts) do
    attrs =
      %{
        key_name: opts[:key],
        app: opts[:app] || "unknown",
        requested_model: opts[:requested_model],
        served_model: deployment.model,
        upstream_model: deployment.upstream_model,
        provider_name: deployment.provider_name,
        stream: opts[:stream]
      }
      |> Map.merge(token_attrs(usage))

    case %Entry{} |> Entry.changeset(attrs) |> Repo.insert() do
      {:ok, _entry} ->
        :ok

      {:error, changeset} ->
        Logger.warning("[usage] failed to record usage: #{inspect(changeset.errors)}")
        :ok
    end
  end

  @doc "List matching rows, newest first."
  def query(filters) do
    filters
    |> base_query()
    |> order_by([u], desc: u.inserted_at, desc: u.id)
    |> limit(^Map.get(filters, :limit, @default_limit))
    |> offset(^Map.get(filters, :offset, 0))
    |> Repo.all()
  end

  @doc "Group matching rows by key, requested model, and served model."
  def summarize(filters) do
    filters
    |> base_query()
    |> group_by([u], [u.key_name, u.requested_model, u.served_model])
    |> order_by([u], [u.key_name, u.requested_model, u.served_model])
    |> select([u], %{
      key_name: u.key_name,
      requested_model: u.requested_model,
      served_model: u.served_model,
      request_count: count(u.id),
      prompt_tokens: coalesce(sum(u.prompt_tokens), 0),
      completion_tokens: coalesce(sum(u.completion_tokens), 0),
      total_tokens: coalesce(sum(u.total_tokens), 0)
    })
    |> Repo.all()
  end

  defp base_query(filters) do
    Enum.reduce(filters, from(u in Entry), fn
      {_key, nil}, acc -> acc
      {:key_name, key}, acc -> where(acc, [u], u.key_name == ^key)
      {:requested_model, model}, acc -> where(acc, [u], u.requested_model == ^model)
      {:from, from}, acc -> where(acc, [u], u.inserted_at >= ^from)
      {:to, to}, acc -> where(acc, [u], u.inserted_at < ^to)
      _other, acc -> acc
    end)
  end

  defp token_attrs(usage) when is_map(usage) do
    prompt = usage["prompt_tokens"]
    completion = usage["completion_tokens"]

    if is_integer(prompt) or is_integer(completion) do
      prompt = prompt || 0
      completion = completion || 0

      %{
        usage_source: "upstream",
        prompt_tokens: prompt,
        completion_tokens: completion,
        total_tokens: prompt + completion
      }
    else
      no_usage_attrs()
    end
  end

  defp token_attrs(_usage), do: no_usage_attrs()

  defp no_usage_attrs do
    %{
      usage_source: "none",
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil
    }
  end
end
