defmodule Svmm.Agents.Transport do
  @moduledoc """
  Outbound port behaviour for dispatching commands to agents.
  """

  alias Svmm.Agents.Command

  @callback send_command(agent_id :: String.t(), command :: Command.t()) ::
              :ok | {:error, term()}
  @callback connected?(agent_id :: String.t()) :: boolean()

  @spec impl() :: module()
  def impl do
    Application.get_env(:svmm, :agent_transport, Svmm.Agents.Transport.Noop)
  end

  @spec send_command(String.t(), Command.t()) :: :ok | {:error, term()}
  def send_command(agent_id, %Command{} = cmd) do
    impl().send_command(agent_id, cmd)
  end

  @spec connected?(String.t()) :: boolean()
  def connected?(agent_id) do
    impl().connected?(agent_id)
  end
end
