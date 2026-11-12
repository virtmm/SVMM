defmodule Svmm.ClusterTest do
  use ExUnit.Case, async: false

  # wait_boot: booting a peer BEAM can exceed the 15s default on a loaded machine.
  # shutdown: :halt skips the graceful-disconnect wait that otherwise costs ~10s per stop.
  @peer_opts %{
    connection: :standard,
    host: ~c"127.0.0.1",
    longnames: true,
    wait_boot: 60_000,
    shutdown: :halt
  }

  defp start_peer(name) do
    cookie = Node.get_cookie() |> Atom.to_charlist()

    {:ok, pid, node} =
      :peer.start(Map.merge(@peer_opts, %{name: name, args: [~c"-setcookie", cookie]}))

    {pid, node}
  end

  # Drop our distribution link first, otherwise :peer.stop/1 waits ~10s for the
  # disconnect before forcing it. The peer is controlled over that link, so it
  # may already be gone by the time we call stop.
  defp stop_peer({pid, node}) do
    Node.disconnect(node)
    :peer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  describe "primary safety check" do
    test "raises when another primary responds on the same host" do
      peer = start_peer(:primary)

      on_exit(fn -> stop_peer(peer) end)

      config = %{
        "DNS_CLUSTER_QUERY" => "127.0.0.1",
        "NODE_NAME" => "replica@127.0.0.1",
        "NODE_ROLE" => "primary",
        "ERLANG_COOKIE" => nil,
        "EKV_DATA_DIR" => nil
      }

      assert_raise RuntimeError, ~r/Another primary is already running/, fn ->
        Svmm.Application.verify_no_existing_primary(config)
      end
    end

    test "succeeds when no primary is running" do
      config = %{
        "DNS_CLUSTER_QUERY" => "192.0.2.99",
        "NODE_NAME" => "primary@127.0.0.1",
        "NODE_ROLE" => "primary",
        "ERLANG_COOKIE" => nil,
        "EKV_DATA_DIR" => nil
      }

      assert :ok == Svmm.Application.verify_no_existing_primary(config)
    end
  end

  describe "supervision tree shape" do
    test "primary role includes EKV and DurableServer" do
      config = %{
        "NODE_NAME" => nil,
        "ERLANG_COOKIE" => nil,
        "NODE_ROLE" => "primary",
        "EKV_DATA_DIR" => "./data/ekv_store",
        "DNS_CLUSTER_QUERY" => nil
      }

      children = Svmm.Application.children_for_role(config)
      child_modules = Enum.map(children, &child_module/1)

      assert EKV in child_modules
      assert DurableServer.Supervisor in child_modules
    end

    test "replica role includes EKV" do
      config = %{
        "NODE_NAME" => nil,
        "ERLANG_COOKIE" => nil,
        "NODE_ROLE" => "replica",
        "EKV_DATA_DIR" => "./data/ekv_replica",
        "DNS_CLUSTER_QUERY" => "10.0.0.100"
      }

      children = Svmm.Application.children_for_role(config)
      child_modules = Enum.map(children, &child_module/1)

      assert EKV in child_modules
      refute DurableServer.Supervisor in child_modules
    end
  end

  defp child_module({module, _opts}) when is_atom(module), do: module
  defp child_module(%{start: {module, _, _}}), do: module
  defp child_module(module) when is_atom(module), do: module
end
