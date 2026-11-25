defmodule SvmmGrpc.ApplicationTest do
  use ExUnit.Case, async: false

  test "a dispatcher crash is restarted without touching the core" do
    registry = Process.whereis(Svmm.Agents.Registry)
    pubsub = Process.whereis(Svmm.PubSub)
    dispatcher = Process.whereis(Svmm.Grpc.CommandDispatcher)
    assert registry && pubsub && dispatcher

    ref = Process.monitor(dispatcher)
    Process.exit(dispatcher, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dispatcher, :killed}

    # Sync with the supervisor so the restart has happened; core pids are unchanged.
    _ = :sys.get_state(SvmmGrpc.Supervisor)
    restarted = Process.whereis(Svmm.Grpc.CommandDispatcher)
    assert is_pid(restarted) and restarted != dispatcher
    assert Process.whereis(Svmm.Agents.Registry) == registry
    assert Process.whereis(Svmm.PubSub) == pubsub
  end

  test "listener is only configured on an enabled primary" do
    refute Enum.any?(SvmmGrpc.Application.children(%{"NODE_ROLE" => "replica"}), &listener?/1)
    refute Enum.any?(SvmmGrpc.Application.children(%{"GRPC_ENABLED" => "false"}), &listener?/1)
    assert Enum.any?(SvmmGrpc.Application.children(%{}), &listener?/1)
  end

  test "the listener actually binds its port (start_server: true)" do
    [{GRPC.Server.Supervisor, opts}] =
      %{"GRPC_PORT" => "50123"} |> SvmmGrpc.Application.children() |> Enum.filter(&listener?/1)

    assert opts[:start_server] == true
    assert opts[:port] == 50123
  end

  defp listener?({GRPC.Server.Supervisor, _}), do: true
  defp listener?(_), do: false
end
