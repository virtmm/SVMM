defmodule SvmmGrpc.MixProject do
  use Mix.Project

  def project do
    [
      app: :svmm_grpc,
      version: "0.3.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {SvmmGrpc.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # gRPC transport adapter for the agent protocol. The core (`:svmm`) must never
  # depend on this app: it talks to agents only through the
  # `Svmm.Agents.Transport` behaviour and the `Svmm.Agents.Ingress` funnel.
  defp deps do
    [
      {:svmm, in_umbrella: true},
      # Wire contract shared with the Go agent. Local path while the repo is
      # unpublished; switch to:
      #   {:svmm_proto, github: "propedeutica/svmm-proto", sparse: "elixir", tag: "v0.1.0"}
      {:svmm_proto, path: "../../../svmm-proto/elixir"},
      {:grpc_server, "~> 1.1"}
    ]
  end
end
