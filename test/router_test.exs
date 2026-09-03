defmodule Llmgateway.RouterTest do
  use ExUnit.Case

  alias Llmgateway.{Auth, Config, Deployment, Router}

  @fixtures_path "test/fixtures"

  defp deployment(opts) do
    base = %{
      name: "m",
      provider_name: "p",
      provider_type: :openai,
      upstream_model: "gpt-5.5",
      api_key: nil,
      base_url: "http://x",
      context: 1,
      output_limit: 1
    }

    %Deployment{} |> Map.merge(base) |> Map.merge(opts)
  end

  setup do
    start_supervised!({Router, Config.load!(Path.join(@fixtures_path, "config.yaml"))})
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
      assert {:ok, deployment, fallbacks} =
               Router.resolve_model("deepseek-v4-flash", key: "work-key")

      assert deployment.name == "deepseek-v4-flash"
      assert fallbacks == ["gpt-4o-mini"]
    end

    test "returns empty fallbacks when none configured" do
      assert {:ok, _deployment, fallbacks} = Router.resolve_model("gpt-4o-mini")
      assert fallbacks == []
    end
  end

  describe "resolve_deployments/2" do
    test "returns all accessible deployments in descending priority order" do
      assert {:ok, deployments, _fallbacks} =
               Router.resolve_deployments("deepseek-v4-flash", key: "personal-key")

      assert Enum.map(deployments, &{&1.provider_name, &1.upstream_model}) == [
               {"openrouter-personal", "deepseek/deepseek-chat"},
               {"openai-main", "gpt-4o-mini"}
             ]

      assert {:ok, first, _fallbacks} =
               Router.resolve_model("deepseek-v4-flash", key: "personal-key")

      assert {first.provider_name, first.upstream_model} ==
               {"openrouter-personal", "deepseek/deepseek-chat"}
    end

    test "retains YAML order for equal priorities" do
      assert {:ok, deployments, _fallbacks} =
               Router.resolve_deployments("tied-model", key: "personal-key")

      assert Enum.map(deployments, & &1.provider_name) == ["openai-main", "openrouter-personal"]
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
      assert work_deploy.upstream_model == "deepseek/deepseek-chat"
      assert personal_deploy.provider_name == "openrouter-personal"
      assert personal_deploy.upstream_model == "deepseek/deepseek-chat"
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

    test "resolves an alias shorthand group child" do
      assert {:ok, deployment, _} = Router.resolve_model("gpt-4o-alias")
      assert deployment.upstream_model == "gpt-4o-mini"
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

  describe "reload/1" do
    test "rebuilds state from a new config" do
      path =
        Path.join(System.tmp_dir!(), "llmgateway_reload_test_#{System.unique_integer([:positive])}.yaml")

      on_exit(fn -> File.rm(path) end)

      # A config identical to the fixture except one keys entry is renamed.
      File.write!(path, """
      server:
        port: 4000
      keys:
        - { name: new-key, value: test-work-key-value }
        - { name: personal-key, value: test-personal-key-value }
      providers:
        - { name: openrouter, type: openrouter, api_key: test-openrouter-key }
        - { name: openrouter-personal, type: openrouter, api_key: test-openrouter-personal-key }
        - { name: openai-main, type: openai, api_key: test-openai-key }
        - { name: copilot-main, type: github_copilot }
      models:
        - provider: openrouter
          keys: [work-key, new-key]
          models: [deepseek-v4-flash:deepseek/deepseek-chat, work-only:gpt-4o-mini]
        - provider: openai-main
          models: [gpt-4o-mini, gpt-4o-alias:gpt-4o-mini]
      fallbacks:
        deepseek-v4-flash: [gpt-4o-mini]
        work-only: [copilot-test]
      """)

      # Setup loaded the fixture: the token resolves under its original name.
      assert {:ok, "work-key"} = Router.resolve_key("test-work-key-value")

      assert :ok = Router.reload(path)

      # After the reload the same token resolves under the renamed key.
      assert {:ok, "new-key"} = Router.resolve_key("test-work-key-value")
      assert {:ok, "personal-key"} = Router.resolve_key("test-personal-key-value")

      # A model only present in the new config resolves; a dropped one does not.
      assert {:ok, _deployment, _} = Router.resolve_model("work-only", key: "new-key")
      assert {:error, :not_found} = Router.resolve_model("tied-model")
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

  describe "key-scoped model aliases" do
    test "logs and ignores an unavailable alias" do
      assert {:error, :not_found} = Router.resolve_model("invalid", key: "personal-key")
      refute Enum.any?(Router.list_models(key: "personal-key"), &(&1.id == "invalid"))
    end

    test "resolves aliases only for their configured key" do
      for alias_name <- ["fast", "default", "slow"] do
        assert {:ok, deployment, _fallbacks} =
                 Router.resolve_model(alias_name, key: "personal-key")

        assert deployment.name == alias_name
        assert is_binary(deployment.upstream_model)
        assert is_atom(deployment.provider_type)
        assert is_integer(deployment.context)
        assert is_integer(deployment.output_limit)
      end

      for alias_name <- ["fast", "default", "slow"] do
        assert {:error, :not_found} = Router.resolve_model(alias_name, key: "work-key")
        assert {:error, :not_found} = Router.resolve_model(alias_name)
      end
    end

    test "lists aliases with backing metadata" do
      models = Router.list_models(key: "personal-key")
      aliases = Map.new(models, &{&1.id, &1})

      for alias_name <- ["fast", "default", "slow"] do
        assert %{owned_by: _, limits: %{context: context, output: output}} = aliases[alias_name]
        assert is_integer(context)
        assert is_integer(output)
      end

      refute Map.has_key?(aliases, "invalid")

      refute Enum.any?(
               Router.list_models(key: "work-key"),
               &(&1.id in ["fast", "default", "slow"])
             )

      refute Enum.any?(Router.list_models(), &(&1.id in ["fast", "default", "slow"]))
    end

    test "exposes each backing model's metadata" do
      models = Map.new(Router.list_models(key: "personal-key"), &{&1.id, &1})

      assert models["fast"].owned_by == "openrouter"
      assert models["fast"].limits == %{context: 163_840, output: 16_000}
      assert models["default"].owned_by == "openai"
      assert models["default"].limits == %{context: 128_000, output: 16_384}
      assert models["slow"].owned_by == "openai"
      assert models["slow"].limits == %{context: 128_000, output: 16_384}
    end

    test "aliases inherit complete backing discovery metadata" do
      models = Map.new(Router.list_models(key: "work-key"), &{&1.id, &1})

      for alias_name <- ["copilot", "luna"] do
        alias_model = models[alias_name]
        backing_model = models["copilot-test"]

        assert alias_model.id == alias_name
        assert backing_model.id == "copilot-test"
        assert alias_model == %{backing_model | id: alias_name}
      end

      # Resolution still routes through the alias while keeping the backing identity internal.
      assert {:ok, alias_deployment, _} = Router.resolve_model("luna", key: "work-key")
      assert {:ok, model_deployment, _} = Router.resolve_model("copilot-test", key: "work-key")
      assert alias_deployment.name == "luna"
      assert alias_deployment.upstream_model == model_deployment.upstream_model
      assert alias_deployment.metadata == model_deployment.metadata
    end
  end

  describe "request_path/1" do
    test "uses llmdb execution path when present" do
      assert Auth.request_path(deployment(%{path: "/responses"})) == "/responses"
    end

    test "falls back to anthropic /v1/messages when no path" do
      d = deployment(%{path: nil, provider_type: :anthropic})
      assert Auth.request_path(d) == "/v1/messages"
    end

    test "defaults to /chat/completions otherwise" do
      assert Auth.request_path(deployment(%{path: nil, provider_type: :openrouter})) ==
               "/chat/completions"
    end
  end

  describe "prepare_request/3" do
    test "converts the body only for a responses deployment" do
      body = %{
        "model" => "gpt-5.5",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      }

      assert {:ok, _req, "/responses", request_body, true} =
               Auth.prepare_request(deployment(%{path: "/responses"}), body, 5_000)

      assert request_body["input"] == [%{"role" => "user", "content" => "Hello"}]
      refute Map.has_key?(request_body, "messages")
    end

    test "keeps the provider body for a chat completions deployment" do
      body = %{
        "model" => "gpt-5.5",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      }

      assert {:ok, _req, "/chat/completions", ^body, false} =
               Auth.prepare_request(deployment(%{path: "/chat/completions"}), body, 5_000)
    end
  end

  describe "provider runtime registry" do
    test "exotic config names do not create atoms" do
      before = :erlang.system_info(:atom_count)

      exotic_names = [
        "github-copilot-\u{1F41B}",
        String.duplicate("long", 40),
        "with spaces and-dashes",
        "Elixir.Llmgateway"
      ]

      for name <- exotic_names do
        assert Llmgateway.ProviderRegistry.github_device(name) == nil
      end

      assert :erlang.system_info(:atom_count) == before

      # A registered server stays reachable under the same exotic name via
      # the registry, still without minting an atom.
      name = "github-copilot-\u{1F41B}"
      {:ok, _owner} = Registry.register(Llmgateway.ProviderRegistry, name, :device)

      assert Llmgateway.ProviderRegistry.github_device(name) ==
               {:via, Registry, {Llmgateway.ProviderRegistry, name}}

      Registry.unregister(Llmgateway.ProviderRegistry, name)
      assert Llmgateway.ProviderRegistry.github_device(name) == nil
      assert :erlang.system_info(:atom_count) == before
    end
  end
end
