defmodule Llmgateway.UsageRoutesTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Llmgateway.{Config, Repo, Router, Server, Usage}
  alias Llmgateway.Usage.Entry

  @admin_token "admin-token-value"
  @work_token "work-token-value"

  setup do
    Repo.delete_all(Entry)

    path = Path.join(System.tmp_dir!(), "usage-routes-#{System.unique_integer([:positive])}.yaml")
    File.write!(path, config_yaml())
    on_exit(fn -> File.rm(path) end)

    {:ok, config} = Config.load(path)
    start_supervised!({Router, config})

    Usage.record(
      %Llmgateway.Deployment{
        name: "fast",
        model: "gpt-4o-mini",
        upstream_model: "gpt-4o-mini-2024",
        provider_name: "openai"
      },
      %{"prompt_tokens" => 4, "completion_tokens" => 2},
      requested_model: "fast",
      key: "admin",
      app: "cli",
      stream: false
    )

    Usage.record(
      %Llmgateway.Deployment{
        name: "fast",
        model: "gpt-4o-mini",
        upstream_model: "gpt-4o-mini-2024",
        provider_name: "openai"
      },
      %{"prompt_tokens" => 1, "completion_tokens" => 1},
      requested_model: "fast",
      key: "work",
      app: "cli",
      stream: false
    )

    :ok
  end

  defp config_yaml do
    """
    providers:
      - name: openai
        type: openai
        api_key: test-openai-key

    models:
      - provider: openai
        models:
          - gpt-4o-mini

    keys:
      - name: admin
        value: #{@admin_token}
      - name: work
        value: #{@work_token}

    settings:
      usage_admin_keys:
        - admin
    """
  end

  defp get_spend(query, token \\ nil) do
    conn = conn(:get, "/spend/logs?" <> query)

    conn =
      if token,
        do: put_req_header(conn, "authorization", "Bearer " <> token),
        else: conn

    Server.call(conn, Server.init([]))
  end

  defp data(conn), do: Jason.decode!(conn.resp_body)["data"]

  test "rejects a request without a valid key when keys are configured" do
    assert get_spend("").status == 401
  end

  test "rejects a non-admin key that asks for another key's rows" do
    assert get_spend("key_name=admin", @work_token).status == 403
  end

  test "rejects an unparseable start_date" do
    conn = get_spend("start_date=not-a-date", @admin_token)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["type"] == "invalid_request_error"
  end

  test "an admin key lists rows from every key" do
    conn = get_spend("", @admin_token)

    assert conn.status == 200
    assert data(conn) |> Enum.map(& &1["key_name"]) |> Enum.sort() == ["admin", "work"]
  end

  test "a non-admin key sees only its own rows" do
    conn = get_spend("", @work_token)

    assert conn.status == 200
    assert [row] = data(conn)
    assert row["key_name"] == "work"
    assert row["requested_model"] == "fast"
    assert row["served_model"] == "gpt-4o-mini"
  end
end
