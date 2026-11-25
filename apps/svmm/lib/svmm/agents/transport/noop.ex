defmodule Svmm.Agents.Transport.Noop do
  @moduledoc """
  Default transport used when no adapter is configured (or none is running).

  Never blocks and never crashes the caller: commands fail fast with
  `{:error, :no_transport}` and no agent is reported as connected.
  """
  @behaviour Svmm.Agents.Transport

  @impl true
  @spec send_command(String.t(), Svmm.Agents.Command.t()) :: {:error, :no_transport}
  def send_command(_agent_id, _command), do: {:error, :no_transport}

  @impl true
  @spec connected?(String.t()) :: false
  def connected?(_agent_id), do: false
end
