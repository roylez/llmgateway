defmodule Llmgateway.DataDirTest do
  use ExUnit.Case, async: false

  alias Llmgateway.DataDir

  @env "LLMGATEWAY_DATA_DIR"

  setup do
    previous = System.get_env(@env)

    on_exit(fn ->
      if previous,
        do: System.put_env(@env, previous),
        else: System.delete_env(@env)
    end)

    System.delete_env(@env)
    :ok
  end

  test "the configured value wins over the environment variable" do
    System.put_env(@env, "/from/env")

    assert DataDir.path("/from/config") == "/from/config"
  end

  test "the environment variable wins over the default" do
    System.put_env(@env, "/from/env")

    assert DataDir.path() == "/from/env"
  end

  test "falls back to ~/.config/llmgateway when neither is set" do
    assert DataDir.path() == Path.join([System.user_home!(), ".config", "llmgateway"])
  end

  test "an empty configured value is ignored" do
    System.put_env(@env, "/from/env")

    assert DataDir.path("") == "/from/env"
  end
end
