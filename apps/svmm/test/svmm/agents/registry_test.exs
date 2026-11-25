defmodule Svmm.Agents.RegistryTest do
  use ExUnit.Case, async: true

  alias Svmm.Agents.Registry

  setup do
    name = :"registry_#{System.unique_integer([:positive])}"
    registry = start_supervised!({Registry, name: name})
    %{registry: registry, name: name}
  end

  test "touch records new agent as online", %{name: name} do
    assert Registry.list_agents(name) == []
    assert Registry.online?("agent-1", name) == false

    Registry.touch("agent-1", %{hostname: "node-1"}, name)
    # Synchronize with GenServer call
    agent = Registry.get_agent("agent-1", name)

    assert agent != nil
    assert agent.agent_id == "agent-1"
    assert agent.status == :online
    assert agent.metadata.hostname == "node-1"
    assert Registry.online?("agent-1", name) == true
  end

  test "mark_offline updates agent status", %{name: name} do
    Registry.touch("agent-1", %{}, name)
    assert Registry.online?("agent-1", name) == true

    Registry.mark_offline("agent-1", "user shutdown", name)
    agent = Registry.get_agent("agent-1", name)

    assert agent.status == :offline
    assert agent.offline_reason == "user shutdown"
    assert Registry.online?("agent-1", name) == false
  end

  test "list_agents returns all registered agents", %{name: name} do
    Registry.touch("agent-1", %{}, name)
    Registry.touch("agent-2", %{}, name)

    agents = Registry.list_agents(name)
    assert length(agents) == 2
    ids = Enum.map(agents, & &1.agent_id) |> Enum.sort()
    assert ids == ["agent-1", "agent-2"]
  end
end
