defmodule Svmm.Grpc.Transport do
  @moduledoc """
  gRPC implementation of `Svmm.Agents.Transport`.
  """
  @behaviour Svmm.Agents.Transport

  alias Svmm.Agents.Command
  alias Svmm.Grpc.CommandDispatcher

  @impl true
  @spec send_command(String.t(), Command.t()) :: :ok | {:error, term()}
  def send_command(agent_id, %Command{} = cmd) do
    CommandDispatcher.send_command(agent_id, cmd)
  end

  @impl true
  @spec connected?(String.t()) :: boolean()
  def connected?(agent_id) do
    CommandDispatcher.connected?(agent_id)
  end
end
