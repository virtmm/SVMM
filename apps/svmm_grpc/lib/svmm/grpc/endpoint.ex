defmodule Svmm.Grpc.Endpoint do
  @moduledoc """
  gRPC Endpoint for SVMM agent communication.
  """
  use GRPC.Endpoint

  run(Svmm.Grpc.AgentServer)
end
