defmodule Svmm.Agents.Command do
  @moduledoc """
  Outbound command sent to an agent.
  """

  @enforce_keys [:action]
  defstruct [:action, params: %{}, id: nil]

  @type t :: %__MODULE__{
          action: atom() | String.t(),
          params: map(),
          id: String.t() | nil
        }
end
