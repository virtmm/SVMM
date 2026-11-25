defmodule Svmm.Agents do
  @moduledoc """
  Context facade for working with agents in the SVMM cluster.
  """

  alias Svmm.Agents.{Command, Registry, Transport}

  @spec command(String.t(), atom() | String.t(), map()) :: :ok | {:error, term()}
  def command(agent_id, action, params \\ %{}) do
    id = "cmd-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
    cmd = %Command{id: id, action: action, params: params}
    Transport.send_command(agent_id, cmd)
  end

  @spec list_agents() :: [map()]
  def list_agents do
    Registry.list_agents()
  end

  @spec get_agent(String.t()) :: map() | nil
  def get_agent(agent_id) do
    Registry.get_agent(agent_id)
  end

  @spec connected?(String.t()) :: boolean()
  def connected?(agent_id) do
    Transport.connected?(agent_id)
  end
end
