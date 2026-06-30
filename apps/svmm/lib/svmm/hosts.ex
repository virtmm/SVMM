defmodule Svmm.Hosts do
  @moduledoc """
  Manages the desired state of physical hosts in the SVMM cluster.
  """
  use DurableServer, vsn: 1

  require Logger

  @spec topic() :: String.t()
  def topic, do: "svmm:hosts"

  # --- Public API ---

  @spec get_hosts() :: {:ok, [String.t()]} | {:error, :not_running}
  def get_hosts do
    with {:ok, pid} <- whereis() do
      {:ok, GenServer.call(pid, :get_hosts)}
    end
  end

  @spec add_host(String.t()) :: :ok | {:error, :not_running}
  def add_host(hostname) do
    with {:ok, pid} <- whereis() do
      GenServer.cast(pid, {:add_host, hostname})
    end
  end

  # Resolves the running Hosts server. lookup/2 returns nil when the server is
  # not started (e.g. on a replica node, or during the boot window before
  # start_primary_services completes) or its node is disconnected.
  @spec whereis() :: {:ok, pid()} | {:error, :not_running}
  defp whereis do
    case DurableServer.Supervisor.lookup(Svmm.DurableServer.Supervisor, topic()) do
      {pid, _meta} when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :not_running}
    end
  end

  # --- DurableServer Callbacks ---

  @impl true
  def init(state) do
    Logger.info("Svmm.Hosts initialized")
    state = Map.merge(%{hosts: []}, state)
    {:ok, state, permanent: true, auto_sync: true}
  end

  @impl true
  def dump_state(state) do
    # We only persist the hosts list. If we had transient data (like active connections),
    # we would filter them out here.
    %{hosts: state.hosts}
  end

  @impl true
  def load_state(_old_vsn, persisted_state) do
    persisted_state
  end

  # --- GenServer Callbacks ---

  @impl true
  def handle_call(:get_hosts, _from, state) do
    {:reply, state.hosts, state}
  end

  @impl true
  def handle_cast({:add_host, hostname}, state) do
    hosts = if hostname in state.hosts, do: state.hosts, else: [hostname | state.hosts]
    {:noreply, %{state | hosts: hosts}}
  end
end
