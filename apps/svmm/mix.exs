defmodule Svmm.MixProject do
  use Mix.Project

  def project do
    [
      app: :svmm,
      version: "0.3.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Svmm.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  # Durable server is a GenServer wrapper that persists state to a backend (EKV). Allows you to define services that need to be running in one server or another.
  # EKV is an embedded key-value store backed by SQLite, with support for distributed duplication and clustering. It supports sharding, observer mode for replicas, and region-based routing

  defp deps do
    [
      {:libcluster, "~> 3.4"},
      {:phoenix_pubsub, "~> 2.1"},
      {:durable_server, "~> 0.1.4"},
      {:ekv, "~> 0.4.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
