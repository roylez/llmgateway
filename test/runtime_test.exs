defmodule Llmgateway.RuntimeTest do
  @moduledoc """
  Boot policy (fail loudly on invalid config) and readiness semantics.
  """
  use ExUnit.Case
  use Plug.Test

  alias Llmgateway.{Config, Router, Runtime, Server}

  @fixtures_path "test/fixtures"

  setup do
    # Tests are sequential; stop leftovers like router_test does.
    try do
      if pid = Process.whereis(Runtime), do: GenServer.stop(pid)
      if pid = Process.whereis(Router), do: GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp load_config do
    {:ok, config} = Config.load(Path.join(@fixtures_path, "config.yaml"))
    config
  end

  defp call(path) do
    Server.call(conn(:get, path), Server.init([]))
  end

  describe "boot policy" do
    test "raises when the config file is missing" do
      assert_raise RuntimeError, ~r/invalid config/, fn ->
        boot_with_config_path("definitely-missing.yaml")
      end
    end

    test "raises when the config is invalid" do
      path = Path.join(System.tmp_dir!(), "llmgateway-invalid-config.yaml")

      File.write!(path, "providers: not-a-list\n")

      try do
        assert_raise RuntimeError, ~r/invalid config/, fn ->
          boot_with_config_path(path)
        end
      after
        File.rm(path)
      end
    end
  end

  describe "GET /ready" do
    test "returns 503 when no valid runtime snapshot exists" do
      {:ok, _} = Router.start_link(load_config())

      conn = call("/ready")
      assert conn.status == 503
      assert Jason.decode!(conn.resp_body)["error"]["type"] == "service_unavailable"
    end

    test "returns 503 when the snapshot is valid but the router is down" do
      {:ok, _} = Runtime.start_link(load_config())

      conn = call("/ready")
      assert conn.status == 503
    end

    test "returns 200 when the snapshot is valid and the router is running" do
      config = load_config()
      {:ok, _} = Router.start_link(config)
      {:ok, _} = Runtime.start_link(config)

      conn = call("/ready")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "ready"
    end

    test "does not require authentication" do
      conn = call("/ready")
      assert conn.status in [200, 503]
      refute conn.status == 401
    end
  end

  describe "GET /health (liveness)" do
    test "returns 200 even when the gateway is not ready" do
      conn = call("/health")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "ok"
    end
  end

  defp boot_with_config_path(path) do
    old = Application.get_env(:llmgateway, :config_path)
    Application.put_env(:llmgateway, :config_path, path)

    try do
      Llmgateway.Application.start(:normal, [])
    after
      if old,
        do: Application.put_env(:llmgateway, :config_path, old),
        else: Application.delete_env(:llmgateway, :config_path)
    end
  end
end
