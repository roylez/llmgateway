defmodule Llmgateway.ConfigTest do
  use ExUnit.Case, async: true

  alias Llmgateway.Config

  @fixtures_path "test/fixtures"

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

      # Models enriched with limits
      model = Enum.find(config["models"], &(&1.name == "gpt-4o-mini"))
      assert model.provider_name == "openai-main"
      assert model.provider_type == :openai
      assert is_integer(model.context)
      assert model.context > 0
    end

    test "resolves $VAR from environment" do
      System.put_env("TEST_LLM_KEY", "resolved-key-value")

      yaml_path = Path.join(@fixtures_path, "config_env.yaml")

      File.write!(yaml_path, """
      providers:
        - name: test-provider
          type: openai
          api_key: $TEST_LLM_KEY
      models:
        - name: test-model
          provider: test-provider
          model: gpt-4o-mini
      """)

      assert {:ok, config} = Config.load(yaml_path)
      [provider] = config["providers"]
      assert provider.api_key == "resolved-key-value"
    after
      System.delete_env("TEST_LLM_KEY")
      File.rm("test/fixtures/config_env.yaml")
    end

    test "fails on missing $VAR" do
      yaml_path = Path.join(@fixtures_path, "config_missing_env.yaml")

      File.write!(yaml_path, """
      providers:
        - name: test-provider
          type: openai
          api_key: $DEFINITELY_NOT_SET_VAR_12345
      models:
        - name: test-model
          provider: test-provider
          model: gpt-4o-mini
      """)

      assert {:error, msg} = Config.load(yaml_path)
      assert msg =~ "DEFINITELY_NOT_SET_VAR_12345"
    after
      File.rm("test/fixtures/config_missing_env.yaml")
    end

    test "fails on missing file" do
      assert {:error, _} = Config.load("nonexistent.yaml")
    end
  end
end
