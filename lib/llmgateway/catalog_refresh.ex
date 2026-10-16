defmodule Llmgateway.CatalogRefresh do
  @moduledoc """
  Refreshes the llm_db catalog from the latest published snapshot every six
  hours. A newly seen snapshot triggers a config reload so enrichment and live
  Copilot metadata pick it up. A failed refresh keeps the current catalog.
  """

  use GenServer
  require Logger

  @interval :timer.hours(6)
  @source {:github_releases, %{ref: :latest}}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Load the latest published snapshot and reload the router when its ID differs
  from `last_snapshot_id`. Returns `{:applied, id}`, `:unchanged`, or `{:error, reason}`.
  """
  def refresh(last_snapshot_id \\ nil) do
    case LLMDB.load(snapshot_source: @source) do
      {:ok, snapshot} -> apply_if_new(snapshot_id(snapshot), last_snapshot_id)
      {:error, reason} -> log_failure(reason)
    end
  end

  @impl true
  def init(_arg) do
    {:ok, %{snapshot_id: nil}}
  end

  @impl true
  def handle_info(:refresh, state) do
    schedule()

    snapshot_id =
      case refresh(state.snapshot_id) do
        {:applied, id} -> id
        _ -> state.snapshot_id
      end

    {:noreply, %{state | snapshot_id: snapshot_id}}
  end

  defp apply_if_new(snapshot_id, snapshot_id), do: :unchanged

  defp apply_if_new(snapshot_id, _last_snapshot_id) do
    case Llmgateway.Router.reload(Application.fetch_env!(:llmgateway, :config_path)) do
      :ok -> {:applied, snapshot_id}
      {:error, reason} -> log_failure(reason)
    end
  end

  defp snapshot_id(snapshot), do: get_in(snapshot, [:meta, :source_snapshot_id])

  defp log_failure(reason) do
    Logger.warning("[catalog] llm_db refresh failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp schedule do
    Process.send_after(self(), :refresh, @interval)
  end
end
