defmodule Svmm.Agents.TransportTest do
  use ExUnit.Case, async: false

  alias Svmm.Agents.{Command, Transport}

  setup do
    previous = Application.fetch_env(:svmm, :agent_transport)
    Application.put_env(:svmm, :agent_transport, Transport.Noop)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:svmm, :agent_transport, value)
        :error -> Application.delete_env(:svmm, :agent_transport)
      end
    end)
  end

  test "Noop transport fails fast without a running adapter" do
    cmd = %Command{action: :start_vm}
    assert Transport.send_command("agent-1", cmd) == {:error, :no_transport}
    refute Transport.connected?("agent-1")
  end
end
