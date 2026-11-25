defmodule Svmm.Agents.Registry do
  @moduledoc """
  Tracks known agents, their metadata, online status, and last seen timestamps.
  """
  use GenServer

  @name __MODULE__

  defstruct agents: %{}

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec touch(String.t(), map(), GenServer.server()) :: :ok
  def touch(agent_id, payload \\ %{}, server \\ @name) do
    GenServer.cast(server, {:touch, agent_id, payload, DateTime.utc_now()})
  end

  @spec mark_offline(String.t(), term(), GenServer.server()) :: :ok
  def mark_offline(agent_id, reason \\ nil, server \\ @name) do
    GenServer.cast(server, {:mark_offline, agent_id, reason, DateTime.utc_now()})
  end

  @spec get_agent(String.t(), GenServer.server()) :: map() | nil
  def get_agent(agent_id, server \\ @name) do
    GenServer.call(server, {:get_agent, agent_id})
  end

  @spec list_agents(GenServer.server()) :: [map()]
  def list_agents(server \\ @name) do
    GenServer.call(server, :list_agents)
  end

  @spec online?(String.t(), GenServer.server()) :: boolean()
  def online?(agent_id, server \\ @name) do
    case get_agent(agent_id, server) do
      %{status: :online} -> true
      _ -> false
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:get_agent, agent_id}, _from, state) do
    {:reply, Map.get(state.agents, agent_id), state}
  end

  @impl true
  def handle_call(:list_agents, _from, state) do
    {:reply, Map.values(state.agents), state}
  end

  @impl true
  def handle_cast({:touch, agent_id, payload, timestamp}, state) do
    existing =
      Map.get(state.agents, agent_id, %{
        agent_id: agent_id,
        created_at: timestamp,
        metadata: %{}
      })

    updated =
      existing
      |> Map.put(:status, :online)
      |> Map.put(:last_seen, timestamp)
      |> Map.update(:metadata, payload, &Map.merge(&1, payload))

    {:noreply, %{state | agents: Map.put(state.agents, agent_id, updated)}}
  end

  @impl true
  def handle_cast({:mark_offline, agent_id, reason, timestamp}, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:noreply, state}

      agent ->
        updated =
          agent
          |> Map.put(:status, :offline)
          |> Map.put(:offline_reason, reason)
          |> Map.put(:offline_at, timestamp)

        {:noreply, %{state | agents: Map.put(state.agents, agent_id, updated)}}
    end
  end
end
