defmodule Svmm.Grpc.CommandDispatcher do
  @moduledoc """
  Manages bidirectional gRPC command streams between SVMM and agents.
  """
  use GenServer
  require Logger

  alias Svmm.Agents.Command

  @name __MODULE__

  defstruct streams: %{}, monitors: %{}, pending: %{}

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec register_stream(String.t(), pid(), GenServer.server()) :: :ok
  def register_stream(agent_id, pid, server \\ @name) do
    GenServer.call(server, {:register_stream, agent_id, pid})
  end

  @spec unregister_stream(String.t(), GenServer.server()) :: :ok
  def unregister_stream(agent_id, server \\ @name) do
    GenServer.call(server, {:unregister_stream, agent_id})
  end

  @spec send_command(String.t(), Command.t(), GenServer.server()) ::
          :ok | {:error, :not_connected}
  def send_command(agent_id, %Command{} = cmd, server \\ @name) do
    GenServer.call(server, {:send_command, agent_id, cmd})
  end

  @spec execute_command(String.t(), Command.t(), timeout(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def execute_command(agent_id, %Command{} = cmd, timeout \\ 10_000, server \\ @name) do
    GenServer.call(server, {:execute_command, agent_id, cmd}, timeout)
  end

  @spec handle_response(map(), GenServer.server()) :: :ok
  def handle_response(response, server \\ @name) do
    GenServer.cast(server, {:handle_response, response})
  end

  @spec connected?(String.t(), GenServer.server()) :: boolean()
  def connected?(agent_id, server \\ @name) do
    GenServer.call(server, {:connected?, agent_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register_stream, agent_id, pid}, _from, state) do
    # Demonitor previous pid for this agent if any
    state =
      case Map.get(state.streams, agent_id) do
        {_old_pid, ref} ->
          Process.demonitor(ref, [:flush])
          %{state | monitors: Map.delete(state.monitors, ref)}

        _ ->
          state
      end

    ref = Process.monitor(pid)
    streams = Map.put(state.streams, agent_id, {pid, ref})
    monitors = Map.put(state.monitors, ref, agent_id)

    Logger.info("Agent #{agent_id} registered gRPC command stream (pid: #{inspect(pid)})")
    {:reply, :ok, %{state | streams: streams, monitors: monitors}}
  end

  @impl true
  def handle_call({:unregister_stream, agent_id}, _from, state) do
    state = remove_agent_stream(state, agent_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:connected?, agent_id}, _from, state) do
    connected = Map.has_key?(state.streams, agent_id)
    {:reply, connected, state}
  end

  @impl true
  def handle_call({:send_command, agent_id, cmd}, _from, state) do
    case Map.get(state.streams, agent_id) do
      nil ->
        {:reply, {:error, :not_connected}, state}

      {pid, _ref} ->
        send(pid, {:push_command, cmd})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:execute_command, agent_id, cmd}, from, state) do
    case Map.get(state.streams, agent_id) do
      nil ->
        {:reply, {:error, :not_connected}, state}

      {pid, _ref} ->
        cmd_id = cmd.id || "cmd-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        cmd_with_id = %{cmd | id: cmd_id}

        send(pid, {:push_command, cmd_with_id})
        pending = Map.put(state.pending, cmd_id, from)
        {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_cast({:handle_response, response}, state) do
    cmd_id = response.id

    state =
      case Map.pop(state.pending, cmd_id) do
        {nil, _pending} ->
          state

        {from, pending} ->
          GenServer.reply(from, {:ok, response})
          %{state | pending: pending}
      end

    # Also broadcast command response to PubSub
    Phoenix.PubSub.broadcast(Svmm.PubSub, "agents", {:command_response, response})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      agent_id ->
        Logger.info("Agent #{agent_id} gRPC command stream disconnected")
        {:noreply, remove_agent_stream(state, agent_id)}
    end
  end

  defp remove_agent_stream(state, agent_id) do
    case Map.get(state.streams, agent_id) do
      nil ->
        state

      {_pid, ref} ->
        Process.demonitor(ref, [:flush])
        streams = Map.delete(state.streams, agent_id)
        monitors = Map.delete(state.monitors, ref)
        %{state | streams: streams, monitors: monitors}
    end
  end
end
