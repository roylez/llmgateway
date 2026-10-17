defmodule Llmgateway.DataDir do
  @moduledoc """
  Resolves the directory holding gateway state: the SQLite database and
  Copilot token caches.

  Precedence: the configured value, then `LLMGATEWAY_DATA_DIR`, then
  `~/.config/llmgateway`.
  """

  @env_var "LLMGATEWAY_DATA_DIR"

  @spec path(String.t() | nil) :: Path.t()
  def path(configured \\ nil) do
    cond do
      non_empty?(configured) -> configured
      non_empty?(System.get_env(@env_var)) -> System.get_env(@env_var)
      true -> Path.join([System.user_home!(), ".config", "llmgateway"])
    end
  end

  defp non_empty?(value), do: is_binary(value) and value != ""
end
