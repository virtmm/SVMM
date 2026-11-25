defmodule Svmm.Agents.Event do
  @moduledoc """
  Inbound normalized event emitted by an agent.
  """

  @enforce_keys [:kind, :agent_id]
  defstruct [:kind, :agent_id, payload: %{}, received_at: nil]

  @type t :: %__MODULE__{
          kind: atom(),
          agent_id: String.t(),
          payload: map(),
          received_at: DateTime.t() | nil
        }
end
