defmodule Svmm.Agents.Ingress do
  @moduledoc """
  Single entry point for all inbound agent events regardless of wire protocol.
  """
  alias Svmm.Agents.{Event, Registry}

  @spec handle(Event.t()) :: :ok
  def handle(%Event{} = ev) do
    Registry.touch(ev.agent_id, ev.payload)
    Phoenix.PubSub.broadcast(Svmm.PubSub, "agents", ev)
    :ok
  end
end
