defmodule Svmm.Grpc.AgentServerTest do
  use ExUnit.Case, async: false

  alias Io.Cloudevents.V1.CloudEvent
  alias Svmm.Agent.V1.AgentService.Stub
  alias Svmm.Agents.{Event, Registry}
  alias Svmm.Grpc.{AgentServer, CommandDispatcher}
  alias SvmmProto.Events

  setup do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    start_supervised!(
      {GRPC.Server.Supervisor, endpoint: Svmm.Grpc.Endpoint, port: port, start_server: true}
    )

    {:ok, channel} = GRPC.Stub.connect("localhost:#{port}")
    on_exit(fn -> GRPC.Stub.disconnect(channel) end)

    Phoenix.PubSub.subscribe(Svmm.PubSub, "agents")
    %{channel: channel}
  end

  test "a heartbeat marks the agent online and is broadcast", %{channel: channel} do
    id = "agent-#{System.unique_integer([:positive])}"
    stream = Stub.connect(channel)

    GRPC.Stub.send_request(stream, Events.new_heartbeat("svmm-agent/#{id}", "0.1.0"))

    assert_receive %Event{kind: :heartbeat, agent_id: ^id, payload: %{agent_version: "0.1.0"}},
                   5_000

    _ = :sys.get_state(Registry)
    assert %{status: :online} = Registry.get_agent(id)
    assert CommandDispatcher.connected?(id)

    GRPC.Stub.end_stream(stream)
  end

  test "unknown event types and bad sources are dropped without killing the stream", %{
    channel: channel
  } do
    id = "agent-#{System.unique_integer([:positive])}"
    stream = Stub.connect(channel)

    GRPC.Stub.send_request(stream, %CloudEvent{
      id: "1",
      source: "svmm-agent/#{id}",
      spec_version: "1.0",
      type: "io.svmm.unknown.v9"
    })

    GRPC.Stub.send_request(stream, %CloudEvent{id: "2", source: "bogus", type: "x"})
    GRPC.Stub.send_request(stream, Events.new_heartbeat("svmm-agent/#{id}", "0.1.0"))

    assert_receive %Event{kind: :heartbeat, agent_id: ^id}, 5_000
    GRPC.Stub.end_stream(stream)
  end

  test "agent_id_from_source/1" do
    assert AgentServer.agent_id_from_source("svmm-agent/host-1") == "host-1"
    assert AgentServer.agent_id_from_source("svmm-agent/") == nil
    assert AgentServer.agent_id_from_source("other/host-1") == nil
    assert AgentServer.agent_id_from_source(nil) == nil
  end
end
