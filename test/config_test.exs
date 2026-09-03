defmodule Llmgateway.ConfigTest do
  use ExUnit.Case

  alias Llmgateway.Config

  @fixtures_path "test/fixtures"

  defp with_tmp_yaml(contents, fun) do
    dir =
      Path.join(System.tmp_dir!(), "llmgateway-config-test-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(dir)
      path = Path.join(dir, "test.yaml")
      File.write!(path, contents)
      fun.(path)
    after
      File.rm_rf!(dir)
    end
  end

  describe "load/1" do
    test "parses a valid config file" do
      assert {:ok, config} = Config.load(Path.join(@fixtures_path, "config.yaml"))

      assert is_list(config["providers"])
      assert is_list(config["models"])
      assert is_list(config["keys"])

      # Providers enriched with llm_db metadata
      [openrouter | _] = config["providers"]
      assert openrouter.name == "openrouter"
      assert openrouter.type == :openrouter
      assert openrouter.api_key == "test-openrouter-key"
      assert is_binary(openrouter.base_url)

      # Group children normalize to the existing enriched flat model shape.
      full =
        Enum.find(
          config["models"],
          &(&1.name == "deepseek-v4-flash" and &1.provider_name == "openrouter")
        )

      assert full.upstream_model == "deepseek/deepseek-chat"
      assert full.keys == ["work-key"]
      assert full.priority == 0
      assert full.path == "/chat/completions"

      shorthand =
        Enum.find(
          config["models"],
          &(&1.name == "deepseek-v4-flash" and &1.provider_name == "openrouter-personal")
        )

      assert shorthand.upstream_model == "deepseek/deepseek-chat"
      assert shorthand.keys == ["personal-key"]

      bare = Enum.find(config["models"], &(&1.name == "gpt-4o-mini"))
      assert bare.provider_name == "openai-main"
      assert bare.provider_type == :openai
      assert bare.upstream_model == "gpt-4o-mini"
      assert bare.keys == nil
      assert is_integer(bare.context)
      assert bare.context > 0
      assert bare.path == "/responses"

      alias_model = Enum.find(config["models"], &(&1.name == "gpt-4o-alias"))
      assert alias_model.upstream_model == "gpt-4o-mini"
      assert alias_model.provider_name == "openai-main"
      assert alias_model.keys == nil

      copilot = Enum.find(config["models"], &(&1.name == "copilot-test"))
      assert copilot.provider_type == :github_copilot
      assert copilot.path == nil

    end

    test "preserves key aliases" do
      {:ok, config} = Config.load(Path.join(@fixtures_path, "config.yaml"))
      personal_key = Enum.find(config["keys"], &(&1["name"] == "personal-key"))

      assert personal_key["aliases"] == %{
               "fast" => "deepseek-v4-flash",
               "default" => "gpt-4o-mini",
               "slow" => "tied-model",
               "invalid" => "missing-model"
             }
    end

    test "rejects malformed key aliases" do
      assert {:error,
              "key aliases must be a map of non-empty alias names to non-empty model names"} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: openai
                     type: openai
                     api_key: test-key
                 keys:
                   - name: test
                     value: test-value
                     aliases: [fast]
                 models:
                   - provider: openai
                     models:
                       - gpt-4o-mini
                 """,
                 &Config.load/1
               )
    end

    test "uses a bare group child as its public name" do
      assert {:ok, config} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: openai
                     type: openai
                     api_key: test-key
                 models:
                   - provider: openai
                     models:
                       - gpt-4o-mini
                 """,
                 &Config.load/1
               )

      [model] = config["models"]
      assert model.name == "gpt-4o-mini"
    end

    test "inherits group priority for every child" do
      assert {:ok, config} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: openai
                     type: openai
                     api_key: test-key
                 models:
                   - provider: openai
                     priority: 10
                     models:
                       - high-priority:gpt-4o-mini
                       - name: another-high-priority
                         model: gpt-4o
                 """,
                 &Config.load/1
               )

      assert Enum.all?(config["models"], &(&1.priority == 10))
    end

    test "rejects duplicate provider names" do
      assert {:error, msg} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: openai
                     type: openai
                     api_key: test-key
                   - name: openai
                     type: openrouter
                     api_key: test-key
                 models:
                   - provider: openai
                     models:
                       - gpt-4o-mini
                 """,
                 &Config.load/1
               )

      assert msg =~ "duplicate provider name(s):"
      assert msg =~ "openai"
    end

    test "rejects duplicate key names" do
      assert {:error, msg} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: openai
                     type: openai
                     api_key: test-key
                 keys:
                   - name: work-key
                     value: first
                   - name: work-key
                     value: second
                 models:
                   - provider: openai
                     models:
                       - gpt-4o-mini
                 """,
                 &Config.load/1
               )

      assert msg =~ "duplicate key name(s):"
      assert msg =~ "work-key"
    end

    test "rejects duplicate public model names within the same provider" do
      assert {:error, msg} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: openai
                     type: openai
                     api_key: test-key
                 models:
                   - provider: openai
                     models:
                       - first:gpt-4o-mini
                       - first:gpt-4o
                 """,
                 &Config.load/1
               )

      assert msg =~ "duplicate model name(s):"
      assert msg =~ "'first' under provider 'openai'"
    end

    test "rejects auth-required provider with unset api_key" do
      assert {:error, msg} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: openai
                     type: openai
                 models:
                   - provider: openai
                     models:
                       - gpt-4o-mini
                 """,
                 &Config.load/1
               )

      assert msg =~ "requires an api_key"
      assert msg =~ "'openai'"
    end

    test "exempts github_copilot from the api_key requirement" do
      assert {:ok, _} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: copilot-main
                     type: github_copilot
                 models:
                   - provider: copilot-main
                     models:
                       - copilot-test:gpt-5.6-luna
                 """,
                 &Config.load/1
               )
    end

    test "rejects duplicate public model names with map children" do
      assert {:error, msg} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: openai
                     type: openai
                     api_key: test-key
                 models:
                   - provider: openai
                     models:
                       - name: shared
                         model: gpt-4o-mini
                       - name: shared
                         model: gpt-4o
                 """,
                 &Config.load/1
               )

      assert msg =~ "duplicate model name(s):"
      assert msg =~ "'shared' under provider 'openai'"
    end

    test "allows the same public name across different providers (multi-deployment)" do
      assert {:ok, config} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: openai
                     type: openai
                     api_key: test-key
                   - name: openrouter
                     type: openrouter
                     api_key: test-key
                 models:
                   - provider: openai
                     models:
                       - shared:gpt-4o-mini
                   - provider: openrouter
                     models:
                       - shared:deepseek/deepseek-chat
                 """,
                 &Config.load/1
               )

      assert length(config["models"]) == 2
    end

    test "rejects a provider that requires auth when api_key resolves to nil" do
      assert {:error, msg} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: openai
                     type: openai
                     api_key: ""
                 models:
                   - provider: openai
                     models:
                       - gpt-4o-mini
                 """,
                 &Config.load/1
               )

      assert msg =~ "provider 'openai' (type 'openai') requires an api_key"
    end

    test "does not require api_key for locally-run providers" do
      assert {:ok, config} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: local
                     type: lmstudio
                 models:
                   - provider: local
                     models:
                       - llama:llama3.2
                 """,
                 &Config.load/1
               )

      [provider] = config["providers"]
      assert is_nil(provider.api_key)
    end

    test "resolves $VAR from environment" do
      System.put_env("TEST_LLM_KEY", "resolved-key-value")

      assert {:ok, config} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: test-provider
                     type: openai
                     api_key: $TEST_LLM_KEY
                 models:
                   - provider: test-provider
                     models:
                       - test-model:gpt-4o-mini
                 """,
                 &Config.load/1
               )

      [provider] = config["providers"]
      assert provider.api_key == "resolved-key-value"
    after
      System.delete_env("TEST_LLM_KEY")
    end

    test "fails on missing $VAR" do
      assert {:error, msg} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: test-provider
                     type: openai
                     api_key: $DEFINITELY_NOT_SET_VAR_12345
                 models:
                   - provider: test-provider
                     models:
                       - test-model:gpt-4o-mini
                 """,
                 &Config.load/1
               )

      assert msg =~ "DEFINITELY_NOT_SET_VAR_12345"
    end

    test "defaults cooldown_seconds to 60 when settings absent" do
      assert {:ok, config} = Config.load(Path.join(@fixtures_path, "config.yaml"))
      assert config["settings"]["cooldown_seconds"] == 60
    end

    test "parses settings cooldown_seconds (0 disables, positive honored)" do
      assert {:ok, config} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: openai
                     type: openai
                     api_key: test-key
                 models:
                   - provider: openai
                     models:
                       - test-model:gpt-4o-mini
                 settings:
                   cooldown_seconds: 0
                 """,
                 &Config.load/1
               )

      assert config["settings"]["cooldown_seconds"] == 0
    end

    test "rejects invalid grouped model declarations" do
      for {models, error} <- [
            {[
               "- provider: openai",
               "  models:",
               "    - ':gpt-4o-mini'"
             ], "model shorthand must be '<name>:<model>' or '<model>'"},
            {[
               "- provider: openai",
               "  models:",
               "    - 'gpt-4o-alias:'"
             ], "model shorthand must be '<name>:<model>' or '<model>'"},
            {[
               "- provider: openai",
               "  models:",
               "    - model: gpt-4o-mini",
               "      keys: [work]"
             ], "model group child must not define 'provider' or 'keys'"},
            {["provider: openai"], "models must be a list"},
            {[
               "- name: gpt-4o-mini",
               "  provider: openai",
               "  model: gpt-4o-mini"
             ], "model entry must define a 'models' group"}
          ] do
        assert {:error, ^error} =
                 with_tmp_yaml(
                   [
                     "providers:\n",
                     "  - name: openai\n",
                     "    type: openai\n",
                     "    api_key: test-key\n",
                     "models:\n",
                     Enum.map_join(models, "\n", &"  #{&1}"),
                     "\n"
                   ],
                   &Config.load/1
                 )
      end
    end

    test "rejects a non-integer model group priority" do
      assert {:error, "model group has invalid 'priority'"} =
               with_tmp_yaml(
                 """
                 providers:
                   - name: openai
                     type: openai
                     api_key: test-key
                 models:
                   - provider: openai
                     priority: high
                     models:
                       - gpt-4o-mini
                 """,
                 &Config.load/1
               )
    end

    test "fails on missing file" do
      assert {:error, _} = Config.load("nonexistent.yaml")
    end
  end
end
