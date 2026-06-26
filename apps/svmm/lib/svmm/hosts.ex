defmodule Svmm.Hosts do
  @moduledoc """
  Manages the desired state of physical hosts in the SVMM cluster.
  """
  use DurableServer, vsn: 1

  alias Phoenix.PubSub
  require Logger

  def topic, do: "svmm:hosts"

  # --- Public API ---

  def get_hosts do
    {pid, _meta} = DurableServer.Supervisor.lookup(Svmm.DurableServer.Supervisor, topic())
    GenServer.call(pid, :get_hosts)
  end

  def add_host(hostname) do
    {pid, _meta} = DurableServer.Supervisor.lookup(Svmm.DurableServer.Supervisor, topic())
    GenServer.cast(pid, {:add_host, hostname})
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
    {:noreply, %{state | hosts: [hostname | state.hosts]}}
  end
end
