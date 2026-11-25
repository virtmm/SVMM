defmodule SvmmGrpc.Application do
  @moduledoc """
  Supervises the gRPC agent transport, independently of the core `:svmm` tree.

  A crash or restart here never touches EKV, DurableServer or the agent
  registry. The command dispatcher runs on every node; the network listener
  only on the primary, and only when `GRPC_ENABLED` is not false.
  """
  use Application

  @impl true
  def start(_type, _args) do
    config = Svmm.Config.load()

    Supervisor.start_link(children(config), strategy: :one_for_one, name: SvmmGrpc.Supervisor)
  end

  @spec children(map()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(config) do
    [{Svmm.Grpc.CommandDispatcher, []}] ++ listener(config)
  end

  defp listener(config) do
    if Svmm.Config.node_role(config) == :primary and Svmm.Config.grpc_enabled?(config) do
      [
        # start_server: true is required, otherwise grpc_server never binds the port.
        {GRPC.Server.Supervisor,
         endpoint: Svmm.Grpc.Endpoint, port: Svmm.Config.grpc_port(config), start_server: true}
      ]
    else
      []
    end
  end
end
