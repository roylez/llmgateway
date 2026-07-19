defmodule Llmgateway.Auth.GitHubDevice do
  @moduledoc """
  GitHub Copilot authentication via device code OAuth flow.

  Uses GitHub's built-in Copilot OAuth app client_id to authenticate,
  then exchanges the GitHub access token for a short-lived Copilot API key.

  ## Flow

  1. First run: device flow → user visits github.com/login/device → access_token
  2. Exchange access_token → Copilot API key via copilot_internal/v2/token
  3. Both tokens cached to disk (~/.config/llmgateway/github_copilot/)
  4. API key auto-refreshes when expired using stored access_token

  ## Config

      providers:
        - name: copilot
          type: github_copilot
          # No api_key or client_id needed — auth is fully automatic
  """

  use GenServer

  require Logger

  @github_client_id "Iv1.b507a08c87ecfe98"
  @device_code_url "https://github.com/login/device/code"
  @access_token_url "https://github.com/login/oauth/access_token"
  @api_key_url "https://api.github.com/copilot_internal/v2/token"
  @grant_type "urn:ietf:params:oauth:grant-type:device_code"

  @github_headers %{
    "accept" => "application/json",
    "editor-version" => "vscode/1.85.1",
    "editor-plugin-version" => "copilot/1.155.0",
    "user-agent" => "GithubCopilot/1.155.0",
    "content-type" => "application/json"
  }

  defstruct [
    :provider_name,
    :access_token,
    :api_key,
    :api_key_expires_at,
    # dynamic base URL from token exchange
    :api_base,
    # %{"gpt-5.5" => ["/responses"], ...}
    :model_endpoints,
    :token_dir,
    :status,
    # timer ref for proactive refresh
    :refresh_timer
  ]

  # ── Client API ────────────────────────────────────────────

  def start_link(opts) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get the current Copilot API key. Initiates device flow if needed.
  Auto-refreshes expired keys.
  """
  def get_token(server \\ __MODULE__) do
    GenServer.call(server, :get_token, 120_000)
  end

  @doc "Get the dynamic API base URL (from token exchange)."
  def get_api_base(server \\ __MODULE__) do
    GenServer.call(server, :get_api_base, 5_000)
  end

  @doc "Get the preferred endpoint path for a model."
  def get_model_endpoint(server \\ __MODULE__, model_id) do
    GenServer.call(server, {:get_model_endpoint, model_id}, 5_000)
  end

  @doc "List known model IDs from Copilot /models cache. Returns [] if not fetched yet."
  def list_known_models(server \\ __MODULE__) do
    GenServer.call(server, :list_known_models, 5_000)
  end

  # ── Server callbacks ──────────────────────────────────────

  @impl true
  def init(opts) do
    provider_name = opts[:provider_name] || "github_copilot"

    base_dir =
      opts[:data_dir] ||
        System.get_env("LLMGATEWAY_DATA_DIR") ||
        Path.join([System.user_home!(), ".config", "llmgateway"])

    token_dir = Path.join(base_dir, "github_copilot_#{provider_name}")

    case File.mkdir_p(token_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[#{provider_name}] Cannot create token dir #{token_dir}: #{reason}. Token caching disabled."
        )
    end

    state = %__MODULE__{
      provider_name: provider_name,
      token_dir: token_dir,
      status: :idle
    }

    state = load_cached_tokens(state)
    {:ok, state, {:continue, :maybe_auth}}
  end

  @impl true
  def handle_continue(:maybe_auth, state) do
    case get_valid_api_key(state) do
      {:ok, _key, state} ->
        Logger.info("[#{state.provider_name}] Using cached Copilot token")

        state =
          if state.model_endpoints,
            do: schedule_refresh(state),
            else: fetch_model_endpoints(state) |> schedule_refresh()

        {:noreply, state}

      {:needs_refresh, state} ->
        Logger.info("[#{state.provider_name}] Refreshing Copilot API key...")

        case refresh_api_key(state) do
          {:ok, _key, refreshed} ->
            {:noreply, refreshed}

          {:error, _} ->
            Logger.info("[#{state.provider_name}] Refresh failed, starting device flow...")
            start_device_flow_eager(state)
            {:noreply, state}
        end

      {:needs_login, state} ->
        start_device_flow_eager(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_token, _from, %{status: :pending} = state) do
    {:reply, {:error, :auth_pending}, state}
  end

  @impl true
  def handle_call(:get_token, _from, state) do
    case get_valid_api_key(state) do
      {:ok, api_key, new_state} ->
        {:reply, {:ok, api_key}, schedule_refresh(new_state)}

      {:needs_refresh, new_state} ->
        case refresh_api_key(new_state) do
          {:ok, api_key, refreshed_state} ->
            {:reply, {:ok, api_key}, refreshed_state}

          {:error, _reason} ->
            {:reply, {:error, :auth_required}, %{new_state | access_token: nil, status: :idle}}
        end

      {:needs_login, _new_state} ->
        {:reply, {:error, :auth_required}, state}
    end
  end

  @impl true
  def handle_call(:get_api_base, _from, state) do
    {:reply, state.api_base || "https://api.githubcopilot.com", state}
  end

  @impl true
  def handle_call({:get_model_endpoint, model_id}, _from, state) do
    endpoints = (state.model_endpoints || %{})[model_id] || ["/chat/completions"]

    # Prefer /chat/completions if available, otherwise first endpoint
    endpoint =
      cond do
        "/chat/completions" in endpoints -> "/chat/completions"
        "/v1/messages" in endpoints -> "/v1/messages"
        true -> List.first(endpoints) || "/chat/completions"
      end

    {:reply, endpoint, state}
  end

  @impl true
  def handle_call(:list_known_models, _from, state) do
    known = (state.model_endpoints || %{}) |> Map.keys() |> Enum.sort()
    {:reply, known, state}
  end

  @impl true
  def handle_cast({:device_flow_result_eager, {:ok, access_token}}, state) do
    Logger.info("[#{state.provider_name}] Device flow successful")

    state = %{state | access_token: access_token, status: :authenticated}
    save_access_token(state)

    case refresh_api_key(state) do
      {:ok, _api_key, new_state} ->
        Logger.info("[#{state.provider_name}] Copilot API key obtained")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("[#{state.provider_name}] API key exchange failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_cast({:device_flow_result_eager, {:error, reason}}, state) do
    Logger.warning("[#{state.provider_name}] Device flow failed: #{inspect(reason)}")
    {:noreply, %{state | status: :idle}}
  end

  # ── Token state checks ───────────────────────────────────

  defp schedule_refresh(state) when is_integer(state.api_key_expires_at) do
    # Cancel any existing timer
    if state.refresh_timer, do: Process.cancel_timer(state.refresh_timer)

    now = :os.system_time(:second)
    delay = max(0, state.api_key_expires_at - now)

    timer = Process.send_after(self(), :refresh_api_key, delay * 1_000)
    %{state | refresh_timer: timer}
  end

  defp schedule_refresh(state), do: state

  @impl true
  def handle_info(:refresh_api_key, state) do
    Logger.debug("[#{state.provider_name}] Proactive API key refresh...")
    state = %{state | refresh_timer: nil}

    case get_valid_api_key(state) do
      {:needs_refresh, state} ->
        case refresh_api_key(state) do
          {:ok, _key, refreshed} ->
            {:noreply, refreshed}

          {:error, _reason} ->
            Logger.warning(
              "[#{state.provider_name}] Proactive refresh failed, will retry on next request"
            )

            {:noreply, state}
        end

      {:ok, _key, state} ->
        # Still valid — reschedule
        {:noreply, schedule_refresh(state)}

      {:needs_login, _state} ->
        {:noreply, state}
    end
  end

  defp get_valid_api_key(%{api_key: key, api_key_expires_at: exp} = state)
       when is_binary(key) and is_integer(exp) do
    if exp > :os.system_time(:second) + 60 do
      {:ok, key, state}
    else
      {:needs_refresh, state}
    end
  end

  defp get_valid_api_key(%{access_token: token} = state) when is_binary(token) do
    {:needs_refresh, state}
  end

  defp get_valid_api_key(state) do
    {:needs_login, state}
  end

  # ── Device flow ───────────────────────────────────────────

  defp start_device_flow_eager(state) do
    case request_device_code() do
      {:ok, device_code, user_code, verification_uri, interval} ->
        print_auth_prompt(user_code, verification_uri)
        parent = self()

        Task.start(fn ->
          result = poll_for_access_token(device_code, interval)
          GenServer.cast(parent, {:device_flow_result_eager, result})
        end)

        {:ok, %{state | status: :pending}}

      {:error, reason} ->
        Logger.warning("[#{state.provider_name}] Device flow failed: #{inspect(reason)}")
        {:ok, %{state | status: :idle}}
    end
  end

  defp print_auth_prompt(user_code, verification_uri) do
    IO.puts("""

    ╔══════════════════════════════════════════════════╗
    ║  GitHub Copilot Authorization                    ║
    ║                                                  ║
    ║  Go to: #{String.pad_trailing(verification_uri, 39)}║
    ║  Enter code: #{String.pad_trailing(user_code, 34)}║
    ╚══════════════════════════════════════════════════╝
    """)
  end

  defp request_device_code do
    case Req.post(@device_code_url,
           json: %{"client_id" => @github_client_id, "scope" => "read:user"},
           headers: @github_headers
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body["device_code"], body["user_code"], body["verification_uri"],
         body["interval"] || 5}

      {:ok, %{status: status, body: body}} ->
        {:error, "device code request failed (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "device code request failed: #{inspect(reason)}"}
    end
  end

  defp poll_for_access_token(device_code, interval, attempts \\ 0) do
    if attempts > 60 do
      {:error, :timeout}
    else
      Process.sleep(interval * 1_000)

      case Req.post(@access_token_url,
             json: %{
               "client_id" => @github_client_id,
               "device_code" => device_code,
               "grant_type" => @grant_type
             },
             headers: @github_headers
           ) do
        {:ok, %{status: 200, body: %{"access_token" => token}}} ->
          {:ok, token}

        {:ok, %{status: 200, body: %{"error" => "authorization_pending"}}} ->
          poll_for_access_token(device_code, interval, attempts + 1)

        {:ok, %{status: 200, body: %{"error" => "slow_down", "interval" => new_interval}}} ->
          poll_for_access_token(device_code, new_interval, attempts + 1)

        {:ok, %{status: 200, body: %{"error" => "expired_token"}}} ->
          {:error, :expired}

        {:ok, %{status: 200, body: %{"error" => "access_denied"}}} ->
          {:error, :denied}

        {:ok, %{body: body}} ->
          {:error, "unexpected: #{inspect(body)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── API key exchange ──────────────────────────────────────
  defp refresh_api_key(%{access_token: token} = state) when is_binary(token) do
    headers = Map.put(@github_headers, "authorization", "token #{token}")

    case Req.get(@api_key_url, headers: headers) do
      {:ok, %{status: 200, body: %{"token" => api_key} = body}} ->
        expires_at = body["expires_at"]

        exp =
          case DateTime.from_iso8601(to_string(expires_at)) do
            {:ok, dt, _} -> DateTime.to_unix(dt)
            _ when is_integer(expires_at) -> expires_at
            _ -> :os.system_time(:second) + 1800
          end

        api_base = get_in(body, ["endpoints", "api"]) || "https://api.githubcopilot.com"

        new_state = %{
          state
          | api_key: api_key,
            api_key_expires_at: exp,
            api_base: api_base,
            status: :authenticated
        }

        save_api_key(new_state)

        # Schedule proactive refresh before expiry
        new_state = schedule_refresh(new_state)

        # Fetch model endpoints in background
        new_state = fetch_model_endpoints(new_state)

        {:ok, api_key, new_state}

      {:ok, %{status: status, body: body}} ->
        {:error, "API key exchange failed (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "API key exchange failed: #{inspect(reason)}"}
    end
  end

  defp fetch_model_endpoints(state) do
    headers = %{
      "authorization" => "Bearer #{state.api_key}",
      "copilot-integration-id" => "vscode-chat",
      "editor-version" => "vscode/1.95.0",
      "user-agent" => "GithubCopilot/1.155.0"
    }

    case Req.get("#{state.api_base}/models", headers: headers) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        endpoints =
          Map.new(models, fn m ->
            {m["id"], m["supported_endpoints"] || ["/chat/completions"]}
          end)

        save_model_endpoints(state, endpoints)
        Logger.debug("[#{state.provider_name}] Cached #{map_size(endpoints)} model endpoints")
        %{state | model_endpoints: endpoints}

      {:ok, %{status: status}} ->
        Logger.warning("[#{state.provider_name}] Failed to fetch models (#{status})")
        load_model_endpoints(state)

      {:error, reason} ->
        Logger.warning("[#{state.provider_name}] Failed to fetch models: #{inspect(reason)}")
        load_model_endpoints(state)
    end
  end

  # ── Disk caching ──────────────────────────────────────────

  defp load_cached_tokens(state) do
    state
    |> load_access_token()
    |> load_api_key()
    |> load_model_endpoints()
  end

  defp load_access_token(state) do
    path = Path.join(state.token_dir, "access-token")

    case File.read(path) do
      {:ok, token} ->
        token = String.trim(token)
        if token != "", do: %{state | access_token: token}, else: state

      _ ->
        state
    end
  end

  defp load_api_key(state) do
    path = Path.join(state.token_dir, "api-key.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"token" => key, "expires_at" => exp} = data} ->
            exp_unix =
              case DateTime.from_iso8601(to_string(exp)) do
                {:ok, dt, _} -> DateTime.to_unix(dt)
                _ when is_integer(exp) -> exp
                _ -> 0
              end

            api_base = data["api_base"] || "https://api.githubcopilot.com"

            %{
              state
              | api_key: key,
                api_key_expires_at: exp_unix,
                api_base: api_base,
                status: :authenticated
            }

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp save_access_token(state) do
    path = Path.join(state.token_dir, "access-token")

    case File.write(path, state.access_token || "") do
      :ok ->
        File.chmod(path, 0o600)

      {:error, reason} ->
        Logger.warning("[#{state.provider_name}] Cannot save access token: #{reason}")
    end
  end

  defp save_api_key(state) do
    path = Path.join(state.token_dir, "api-key.json")

    data =
      Jason.encode!(%{
        "token" => state.api_key,
        "expires_at" => state.api_key_expires_at,
        "api_base" => state.api_base
      })

    case File.write(path, data) do
      :ok ->
        File.chmod(path, 0o600)

      {:error, reason} ->
        Logger.warning("[#{state.provider_name}] Cannot save API key: #{reason}")
    end
  end

  defp save_model_endpoints(state, endpoints) do
    path = Path.join(state.token_dir, "models.json")

    case File.write(path, Jason.encode!(endpoints)) do
      :ok -> File.chmod(path, 0o600)
      {:error, reason} -> Logger.warning("[#{state.provider_name}] Cannot save models: #{reason}")
    end
  end

  defp load_model_endpoints(state) do
    path = Path.join(state.token_dir, "models.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, endpoints} when is_map(endpoints) ->
            %{state | model_endpoints: endpoints}

          _ ->
            state
        end

      _ ->
        state
    end
  end
end
