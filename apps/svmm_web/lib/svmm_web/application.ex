defmodule SvmmWeb.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SvmmWeb.Telemetry,
      # Start a worker by calling: SvmmWeb.Worker.start_link(arg)
      # {SvmmWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      SvmmWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SvmmWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SvmmWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
