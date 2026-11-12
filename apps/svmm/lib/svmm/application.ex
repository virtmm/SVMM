defmodule Svmm.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc """
  Starts the application supervision tree, and sets up the node name and cookie for distributed operation.
  It uses helpers and other things to make sure that the node is started with the proper configuration for the role.
  Primary nodes (:primary) will start the EKV database and the Phoenix Endpoint, while replica nodes (:replica) will only start EKV, connect to the primary, and copy the dataabse.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    config = Svmm.Config.load()
    role = Svmm.Config.node_role(config)

    setup_distribution(config)

    if role == :primary do
      verify_no_existing_primary(config)
    end

    children = children_for_role(config)

    {:ok, pid} = Supervisor.start_link(children, strategy: :one_for_one, name: Svmm.Supervisor)

    if role == :primary, do: start_primary_services()

    {:ok, pid}
  end

  defp topologies(config) do
    case Svmm.Config.primary_address(config) do
      nil ->
        []

      addr ->
        [
          svmm: [
            strategy: Cluster.Strategy.Epmd,
            config: [hosts: [:"primary@#{addr}"]]
          ]
        ]
    end
  end

  # A primary without its domain servers cannot do its job (and would serve the
  # web UI over missing state), so a failure here aborts boot instead of being
  # logged and ignored.
  defp start_primary_services do
    case DurableServer.Supervisor.ensure_started_child(
           Svmm.DurableServer.Supervisor,
           {Svmm.Hosts, key: Svmm.Hosts.topic(), initial_state: %{hosts: []}}
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise "Failed to start Svmm.Hosts durable server: #{inspect(reason)}"
    end
  end

  defp setup_distribution(config) do
    node_name = Svmm.Config.node_name(config)
    cookie = Svmm.Config.cookie(config)

    if node_name && not Node.alive?() do
      case Node.start(node_name, name_domain: :longnames) do
        {:ok, _pid} ->
          Logger.info("Node started with name #{node_name}")

        {:error, {:already_started, _pid}} ->
          Logger.info("Node already started with name #{node_name}")

        {:error, reason} ->
          raise "Failed to start node: #{inspect(reason)}"
      end
    end

    # Set the cookie whenever one is configured and the node is distributed,
    # even when the BEAM was started already-alive (e.g. `iex --name ...`).
    # Otherwise the configured ERLANG_COOKIE is silently ignored and clustering
    # falls back to ~/.erlang.cookie.
    if cookie && Node.alive?() do
      Node.set_cookie(cookie)
      Logger.debug("Node cookie set to #{cookie}")
    end
  end

  @spec children_for_role(map()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children_for_role(config) do
    role = Svmm.Config.node_role(config)

    [
      {Cluster.Supervisor, [topologies(config), [name: Svmm.ClusterSupervisor]]},
      {Phoenix.PubSub, name: Svmm.PubSub}
    ] ++ role_children(role, config)
  end

  defp role_children(:primary, config) do
    ekv_config = ekv_config(config, :member)

    [
      {EKV, ekv_config},
      {DurableServer.Supervisor,
       name: Svmm.DurableServer.Supervisor,
       prefix: "svmm/",
       backend: {DurableServer.Backends.EKVStore, [name: ekv_config[:name], start: false]}}
    ]
  end

  defp role_children(:replica, config) do
    ekv_config = ekv_config(config, :observer)

    [
      {EKV, ekv_config}
    ]
  end

  defp ekv_config(config, mode) do
    base = [
      name: :svmm_cluster,
      data_dir: Svmm.Config.ekv_data_dir(config),
      cluster_size: Svmm.Config.cluster_size(config),
      shards: Svmm.Config.ekv_shards(config)
    ]

    case mode do
      :member -> base
      :observer -> base ++ [mode: :observer, region: "replica", region_routing: ["default"]]
    end
  end

  @spec verify_no_existing_primary(map()) :: :ok
  def verify_no_existing_primary(config) do
    primary_address = Svmm.Config.primary_address(config)

    # Exclude *this* running node, not the operator-declared NODE_NAME. In the
    # documented HA setup NODE_NAME is `primary@<DNS_CLUSTER_QUERY>`, which is
    # exactly the name we build below, so comparing against the configured name
    # always matched and skipped the ping — letting a second primary boot.
    with true <- primary_address != nil,
         true <- Node.alive?(),
         primary_node = :"primary@#{primary_address}",
         true <- primary_node != Node.self(),
         :pong <- :net_adm.ping(primary_node) do
      raise """
      Another primary is already running at #{primary_node}.
      Start this node in replica mode instead:

          NODE_ROLE=replica
      """
    else
      _ -> :ok
    end
  end
end
