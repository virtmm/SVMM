defmodule Svmm.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DNSCluster, query: Application.get_env(:svmm, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Svmm.PubSub}
      # Start a worker by calling: Svmm.Worker.start_link(arg)
      # {Svmm.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Svmm.Supervisor)
  end
end
