defmodule Llmgateway.RouterTest do
  use ExUnit.Case

  alias Llmgateway.{Config, Router}

  @fixtures_path "test/fixtures"

  setup do
    try do
      if pid = Process.whereis(Router), do: GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end

    {:ok, config} = Config.load(Path.join(@fixtures_path, "config.yaml"))
    {:ok, _pid} = Router.start_link(config)
    :ok
  end

  describe "resolve_model/2" do
    test "resolves a known model" do
      assert {:ok, deployment, _fallbacks} = Router.resolve_model("gpt-4o-mini")
      assert deployment.name == "gpt-4o-mini"
      assert deployment.provider_type == :openai
      assert deployment.upstream_model == "gpt-4o-mini"
      assert is_binary(deployment.base_url)
      assert is_integer(deployment.context)
    end

    test "returns :not_found for unknown model" do
      assert {:error, :not_found} = Router.resolve_model("nonexistent-model")
    end

    test "returns fallback chain" do
      assert {:ok, deployment, fallbacks} = Router.resolve_model("deepseek-v4-flash", key: "work-key")
      assert deployment.name == "deepseek-v4-flash"
      assert fallbacks == ["gpt-4o-mini"]
    end

    test "returns empty fallbacks when none configured" do
      assert {:ok, _deployment, fallbacks} = Router.resolve_model("gpt-4o-mini")
      assert fallbacks == []
    end
  end

  describe "key-based access control" do
    test "model with no keys is accessible by any key" do
      assert {:ok, _deployment, _} = Router.resolve_model("gpt-4o-mini", key: "work-key")
      assert {:ok, _deployment, _} = Router.resolve_model("gpt-4o-mini", key: "personal-key")
    end

    test "model with keys is accessible by listed keys" do
      assert {:ok, deployment, _} = Router.resolve_model("deepseek-v4-flash", key: "work-key")
      assert deployment.provider_name == "openrouter"
    end

    test "model with no keys is accessible without key" do
      assert {:ok, _deployment, _} = Router.resolve_model("gpt-4o-mini")
    end
  end

  describe "multi-deployment models" do
    test "same model name resolves to different providers by key" do
      {:ok, work_deploy, _} = Router.resolve_model("deepseek-v4-flash", key: "work-key")
      {:ok, personal_deploy, _} = Router.resolve_model("deepseek-v4-flash", key: "personal-key")

      assert work_deploy.provider_name == "openrouter"
      assert personal_deploy.provider_name == "openrouter-personal"
      assert work_deploy.name == personal_deploy.name
    end

    test "without key, key-restricted model is forbidden" do
      result = Router.resolve_model("deepseek-v4-flash")
      assert match?({:error, :forbidden}, result) or match?({:error, :forbidden, _}, result)
    end

    test "list_models without key excludes key-restricted models" do
      models = Router.list_models()
      names = Enum.map(models, & &1.id)
      refute "deepseek-v4-flash" in names
      assert "gpt-4o-mini" in names
    end

    test "list_models picks deployment matching the key" do
      work_models = Router.list_models(key: "work-key")
      personal_models = Router.list_models(key: "personal-key")

      work_deepseek = Enum.find(work_models, &(&1.id == "deepseek-v4-flash"))
      personal_deepseek = Enum.find(personal_models, &(&1.id == "deepseek-v4-flash"))

      assert work_deepseek != nil
      assert personal_deepseek != nil
    end
  end

  describe "resolve_key/1" do
    test "resolves a valid key token" do
      assert {:ok, "work-key"} = Router.resolve_key("test-work-key-value")
      assert {:ok, "personal-key"} = Router.resolve_key("test-personal-key-value")
    end

    test "rejects invalid key token" do
      assert {:error, :invalid_key} = Router.resolve_key("bad-token")
    end
  end

  describe "list_models/1" do
    test "lists unrestricted models without key filter" do
      models = Router.list_models()
      names = Enum.map(models, & &1.id)
      assert "gpt-4o-mini" in names
      # key-restricted models not shown without a key
      refute "deepseek-v4-flash" in names
    end

    test "includes model limits" do
      [model | _] = Router.list_models()
      assert is_map(model.limits)
      assert Map.has_key?(model.limits, :context)
    end
  end
end
