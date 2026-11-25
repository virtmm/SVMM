defmodule Svmm.Grpc.AgentServer do
  @moduledoc """
  gRPC server implementation of `Svmm.Agent.V1.AgentService`.

  The service has one RPC, `Connect`, a bidirectional stream of CloudEvents (see the
  `svmm-proto` repository). Each inbound event is mapped to a `Svmm.Agents.Event` and
  handed to `Svmm.Agents.Ingress`. Unknown event types are logged and dropped so a
  newer agent never breaks an older server.

  Outbound events (commands) are not defined in the contract yet: a command pushed by
  `Svmm.Grpc.CommandDispatcher` is logged and dropped until its message is added to
  `svmm-proto`.
  """
  use GRPC.Server, service: Svmm.Agent.V1.AgentService.Service
  require Logger

  alias Io.Cloudevents.V1.CloudEvent
  alias Svmm.Agents.{Event, Ingress, Registry}
  alias Svmm.Grpc.CommandDispatcher
  alias SvmmProto.Events

  @source_prefix "svmm-agent/"

  @spec connect(Enumerable.t(), GRPC.Server.Stream.t()) :: :ok
  def connect(req_enum, _stream) do
    handler = self()

    reader =
      Task.async(fn ->
        Enum.each(req_enum, &send(handler, {:cloud_event, &1}))
        send(handler, :client_finished)
      end)

    try do
      loop(nil)
    after
      Task.shutdown(reader, :brutal_kill)
    end
  end

  defp loop(agent_id) do
    receive do
      {:cloud_event, %CloudEvent{} = ev} ->
        loop(handle_event(ev, agent_id))

      {:push_command, cmd} ->
        Logger.warning(
          "Dropping command #{inspect(cmd.action)}: no command message in svmm-proto yet"
        )

        loop(agent_id)

      :client_finished ->
        disconnected(agent_id)

      {:DOWN, _ref, :process, _pid, _reason} ->
        disconnected(agent_id)

      {ref, _result} when is_reference(ref) ->
        loop(agent_id)
    end
  end

  # Returns the agent id learned from the event source.
  defp handle_event(%CloudEvent{} = ev, agent_id) do
    case agent_id_from_source(ev.source) do
      nil ->
        Logger.warning("Dropping event #{ev.id}: invalid source #{inspect(ev.source)}")
        agent_id

      id ->
        if id != agent_id, do: CommandDispatcher.register_stream(id, self())
        dispatch(ev, id)
        id
    end
  end

  defp dispatch(%CloudEvent{type: type} = ev, agent_id) do
    if type == Events.type_heartbeat() do
      case Events.parse_heartbeat(ev) do
        {:ok, hb} ->
          Ingress.handle(%Event{
            kind: :heartbeat,
            agent_id: agent_id,
            payload: %{agent_version: hb.agent_version, sent_at: hb.sent_at},
            received_at: DateTime.utc_now()
          })

        {:error, reason} ->
          Logger.warning("Bad heartbeat from #{agent_id}: #{inspect(reason)}")
      end
    else
      Logger.info("Ignoring unsupported event type #{inspect(type)} from #{agent_id}")
    end
  end

  defp disconnected(nil), do: :ok

  defp disconnected(agent_id) do
    CommandDispatcher.unregister_stream(agent_id)
    Registry.mark_offline(agent_id, :disconnected)
    :ok
  end

  @doc false
  @spec agent_id_from_source(term()) :: String.t() | nil
  def agent_id_from_source(@source_prefix <> id) when id != "", do: id
  def agent_id_from_source(_), do: nil
end
