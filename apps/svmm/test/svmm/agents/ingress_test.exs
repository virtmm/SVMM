defmodule Svmm.Agents.IngressTest do
  use ExUnit.Case, async: false

  alias Svmm.Agents.{Event, Ingress, Registry}

  test "handle touches registry and broadcasts to PubSub" do
    Phoenix.PubSub.subscribe(Svmm.PubSub, "agents")

    event = %Event{
      kind: :registration,
      agent_id: "test-agent-ingress",
      payload: %{hostname: "test-host"},
      received_at: DateTime.utc_now()
    }

    assert Ingress.handle(event) == :ok

    assert_receive %Event{
      kind: :registration,
      agent_id: "test-agent-ingress",
      payload: %{hostname: "test-host"}
    }

    agent = Registry.get_agent("test-agent-ingress")
    assert agent != nil
    assert agent.status == :online
  end
end
