defmodule Llmgateway.UsageRoutes do
  @moduledoc """
  `GET /spend/logs`: recorded token usage, scoped by API key.

  Admin keys see every row; any other valid key sees only its own rows.
  """
  import Plug.Conn

  alias Llmgateway.{Responses, Router, Usage}

  @default_limit 100
  @max_limit 1000

  def spend_logs(conn) do
    conn = fetch_query_params(conn)

    case Router.usage_scope(conn.assigns[:key_name]) do
      :denied ->
        respond(conn, 401, "Authentication required", "authentication_error")

      {:own, own_key} ->
        if conn.query_params["key_name"] in [nil, own_key] do
          run_query(conn, own_key)
        else
          respond(conn, 403, "Keys may only query their own usage", "access_forbidden")
        end

      :all ->
        run_query(conn, conn.query_params["key_name"])
    end
  end

  defp run_query(conn, key_name) do
    params = conn.query_params

    with {:ok, range} <- date_range(params),
         {:ok, limit} <- int_param(params, "limit", @default_limit, 1, @max_limit),
         {:ok, offset} <- int_param(params, "offset", 0, 0, nil) do
      filters =
        Map.merge(range, %{
          key_name: key_name,
          requested_model: params["model"],
          limit: limit,
          offset: offset
        })

      data =
        if params["summarize"] == "true" do
          Enum.map(Usage.summarize(filters), &summary_entry/1)
        else
          Enum.map(Usage.query(filters), &row_entry/1)
        end

      Responses.send_json(conn, 200, %{"data" => data})
    else
      {:error, message} -> respond(conn, 400, message, "invalid_request_error")
    end
  end

  # start_date / end_date are inclusive calendar days; `to` is exclusive.
  defp date_range(params) do
    with {:ok, from} <- parse_day(params["start_date"]),
         {:ok, to} <- parse_day(params["end_date"]) do
      {:ok,
       %{
         from: from && day_start(from),
         to: to && day_start(Date.add(to, 1))
       }}
    end
  end

  defp parse_day(nil), do: {:ok, nil}

  defp parse_day(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "start_date and end_date must be YYYY-MM-DD"}
    end
  end

  defp day_start(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp int_param(params, name, default, min, max) do
    case params[name] do
      nil ->
        {:ok, default}

      value ->
        case Integer.parse(value) do
          {int, ""} ->
            if in_bounds?(int, min, max),
              do: {:ok, int},
              else: {:error, "#{name} is out of range"}

          _ ->
            {:error, "#{name} must be an integer"}
        end
    end
  end

  defp in_bounds?(int, min, max), do: int >= min and (is_nil(max) or int <= max)

  defp summary_entry(row) do
    %{
      "key_name" => row.key_name,
      "requested_model" => row.requested_model,
      "served_model" => row.served_model,
      "request_count" => row.request_count,
      "prompt_tokens" => row.prompt_tokens,
      "completion_tokens" => row.completion_tokens,
      "total_tokens" => row.total_tokens
    }
  end

  defp row_entry(entry) do
    %{
      "id" => entry.id,
      "key_name" => entry.key_name,
      "app" => entry.app,
      "requested_model" => entry.requested_model,
      "served_model" => entry.served_model,
      "upstream_model" => entry.upstream_model,
      "provider_name" => entry.provider_name,
      "stream" => entry.stream,
      "usage_source" => entry.usage_source,
      "prompt_tokens" => entry.prompt_tokens,
      "completion_tokens" => entry.completion_tokens,
      "total_tokens" => entry.total_tokens,
      "inserted_at" => DateTime.to_iso8601(entry.inserted_at)
    }
  end

  defp respond(conn, status, message, type) do
    Responses.send_json(conn, status, Responses.error_body(message, type))
  end
end
