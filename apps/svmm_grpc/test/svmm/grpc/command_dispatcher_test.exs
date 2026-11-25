defmodule Svmm.Grpc.CommandDispatcherTest do
  use ExUnit.Case, async: true

  alias Svmm.Agents.Command
  alias Svmm.Grpc.CommandDispatcher

  setup do
    name = :"dispatcher_#{System.unique_integer([:positive])}"
    dispatcher = start_supervised!({CommandDispatcher, name: name})
    %{dispatcher: dispatcher, name: name}
  end

  test "register_stream and send_command", %{name: name} do
    refute CommandDispatcher.connected?("agent-test", name)

    assert CommandDispatcher.register_stream("agent-test", self(), name) == :ok
    assert CommandDispatcher.connected?("agent-test", name)

    cmd = %Command{id: "cmd-1", action: :start_vm, params: %{"vm_id" => "123"}}
    assert CommandDispatcher.send_command("agent-test", cmd, name) == :ok

    assert_receive {:push_command, ^cmd}

    assert CommandDispatcher.unregister_stream("agent-test", name) == :ok
    refute CommandDispatcher.connected?("agent-test", name)

    assert CommandDispatcher.send_command("agent-test", cmd, name) == {:error, :not_connected}
  end

  test "execute_command synchronously awaits response", %{name: name} do
    CommandDispatcher.register_stream("agent-test", self(), name)

    task =
      Task.async(fn ->
        cmd = %Command{id: "sync-cmd", action: :stop_vm, params: %{}}
        CommandDispatcher.execute_command("agent-test", cmd, 5000, name)
      end)

    assert_receive {:push_command, %Command{id: "sync-cmd", action: :stop_vm}}

    # Agent sends response
    response = %{id: "sync-cmd", agent_id: "agent-test", success: true}
    CommandDispatcher.handle_response(response, name)

    assert {:ok, ^response} = Task.await(task)
  end

  test "demonitors on stream process termination", %{name: name} do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    CommandDispatcher.register_stream("ephemeral-agent", pid, name)
    assert CommandDispatcher.connected?("ephemeral-agent", name)

    send(pid, :stop)
    # Give time for DOWN message
    _ = :sys.get_state(Process.whereis(name))

    refute CommandDispatcher.connected?("ephemeral-agent", name)
  end
end
