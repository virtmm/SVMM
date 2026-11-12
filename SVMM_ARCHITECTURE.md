# SVMM - Architecture & Setup Guide

SVMM (Simple Virtual Machine Manager) is an Elixir umbrella application that manages physical hosts and their virtual machines. It uses a primary/replica architecture: the primary runs the full stack (EKV + DurableServer + Phoenix), replicas run EKV in observer mode and sync data from the primary via Erlang distribution.

---

## 1. Project Generation

```bash
mix phx.new svmm --umbrella --no-ecto --no-mailer --no-dashboard
```

- `--umbrella`: creates `apps/svmm/` (core OTP app) and `apps/svmm_web/` (Phoenix web app)
- `--no-ecto`: no database — persistence is handled by EKV (embedded key-value store backed by SQLite)
- `--no-mailer`, `--no-dashboard`: not needed

```
svmm_umbrella/
  apps/
    svmm/           # core OTP logic, config, durable state, domain modules
    svmm_web/       # Phoenix endpoint, LiveView UI, router
  config/           # shared config (config.exs, dev.exs, test.exs, runtime.exs, prod.exs)
  mix.exs           # umbrella root
  scripts/          # dev/ops scripts
```

---

## 2. Dependencies

### 2.1 Core app (`apps/svmm/mix.exs`)

```elixir
defp deps do
  [
    {:libcluster, "~> 3.4"},
    {:phoenix_pubsub, "~> 2.1"},
    {:durable_server, "~> 0.1.4"},
    {:ekv, "~> 0.4.0"}
  ]
end
```

| Dependency | Purpose |
|---|---|
| `libcluster` | Automatic cluster formation using pluggable strategies (EPMD, DNS, gossip). Replaces the simpler `dns_cluster` — used here with the `Cluster.Strategy.Epmd` strategy. |
| `phoenix_pubsub` | In-process pub/sub for broadcasting state changes to LiveViews. |
| `durable_server` | GenServer wrapper that persists state to an EKV backend. Handles `dump_state`, `load_state`, versioning (`vsn`), `permanent: true`, and `auto_sync: true`. |
| `ekv` | Embedded key-value store backed by SQLite. Supports sharding, observer mode for replicas, and region-based routing. |

### 2.2 Web app (`apps/svmm_web/mix.exs`)

```elixir
defp deps do
  [
    {:phoenix, "~> 1.8.8"},
    {:phoenix_html, "~> 4.1"},
    {:phoenix_live_reload, "~> 1.2", only: :dev},
    {:phoenix_live_view, "~> 1.2.0"},
    {:lazy_html, ">= 0.1.0", only: :test},
    {:phoenix_live_dashboard, "~> 0.8.3"},
    {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
    {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
    {:heroicons,
     github: "tailwindlabs/heroicons",
     tag: "v2.2.0",
     sparse: "optimized",
     app: false,
     compile: false,
     depth: 1},
    {:telemetry_metrics, "~> 1.0"},
    {:telemetry_poller, "~> 1.0"},
    {:gettext, "~> 1.0"},
    {:svmm, in_umbrella: true},
    {:jason, "~> 1.2"},
    {:bandit, "~> 1.5"}
  ]
end
```

### 2.3 Compile-time config in `apps/svmm_web/mix.exs`

Add to `project/0`:

```elixir
compilers: [:phoenix_live_view] ++ Mix.compilers(),
listeners: [Phoenix.CodeReloader]
```

---

## 3. Configuration Files

### 3.1 `config/config.exs`

```elixir
import Config

config :svmm_web,
  generators: [context_app: :svmm]

config :svmm_web, SvmmWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SvmmWeb.ErrorHTML, json: SvmmWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Svmm.PubSub,
  live_view: [signing_salt: "<generate-with-mix-phx.gen.secret-32>"]

config :phoenix_live_view,
  root_tag_attribute: "phx-r"

config :esbuild,
  version: "0.25.4",
  svmm_web: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/svmm_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.3.0",
  svmm_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/svmm_web", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
```

### 3.2 `config/test.exs`

```elixir
import Config

config :svmm_web, SvmmWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "<generate-with-mix-phx.gen.secret>",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix,
  sort_verified_routes_query_params: true

config :svmm,
  ekv_data_dir: Path.join(System.tmp_dir!(), "svmm_test_ekv")
```

### 3.3 `config/prod.exs`

```elixir
import Config

config :svmm_web, SvmmWeb.Endpoint,
  url: [host: "example.com", port: 80],
  cache_static_manifest: "priv/static/cache_manifest.json"

config :svmm_web, SvmmWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [hosts: ["localhost", "127.0.0.1"]]
  ]

config :logger, level: :info
```

### 3.4 `config/runtime.exs`

```elixir
import Config

config :svmm_web, SvmmWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing."

  # PHX_HOST falls back to DNS_CLUSTER_QUERY so replicas promoted to primary
  # automatically serve the right hostname without extra configuration.
  host = System.get_env("PHX_HOST") || System.get_env("DNS_CLUSTER_QUERY") || "localhost"

  config :svmm_web, SvmmWeb.Endpoint,
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  config :svmm, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  for {env_key, app_key} <- [
        {"NODE_ROLE", :node_role},
        {"NODE_NAME", :node_name},
        {"ERLANG_COOKIE", :erlang_cookie},
        {"EKV_DATA_DIR", :ekv_data_dir}
      ] do
    if value = System.get_env(env_key) do
      config :svmm, [{app_key, value}]
    end
  end
end
```

---

## 4. Configuration Module (`Svmm.Config`)

Reads from `./svmm.conf` or `/etc/svmm.conf` (dotenv-style) and merges it with environment variables and `Application.get_env/2`.

**Configuration priority (highest to lowest):**

```
Application.get_env(:svmm, key) > environment variables > svmm.conf file
```

The file can also be used as a systemd `EnvironmentFile`.

The file is the lowest-priority source so that an operator can override any value for a single run with an environment variable. In `prod`, `config/runtime.exs` copies `NODE_ROLE`, `NODE_NAME`, `ERLANG_COOKIE` and `EKV_DATA_DIR` env vars into the application environment, so those take effect through the highest-priority source.

### Environment variables reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `NODE_ROLE` | No | `primary` | `primary` or `replica` |
| `NODE_NAME` | Yes (for clustering) | `nil` | Full Erlang node name, e.g. `primary@10.0.0.1` |
| `ERLANG_COOKIE` | No | VM default | Shared cookie for all nodes. Dev scripts default to `svmm_dev`. |
| `EKV_DATA_DIR` | No | `<cwd>/data/ekv_store` | Directory where EKV stores SQLite shard files |
| `DNS_CLUSTER_QUERY` | No | `nil` | IP/hostname of the primary node (used by libcluster EPMD to connect) |
| `CLUSTER_SIZE` | No | `1` | Number of EKV cluster members |
| `EKV_SHARDS` | No | `2` | Number of EKV SQLite shards |
| `PORT` | No | `4000` | HTTP port for Phoenix |
| `SECRET_KEY_BASE` | Yes in prod | — | Phoenix secret key base |
| `PHX_HOST` | No in prod | `DNS_CLUSTER_QUERY` | Public hostname for URL generation |

### Public API

```elixir
Svmm.Config.load()            # %{String.t() => String.t() | nil}
Svmm.Config.node_role(config) # :primary | :replica
Svmm.Config.node_name(config) # atom() | nil
Svmm.Config.cookie(config)    # atom() | nil
Svmm.Config.primary_address(config)  # String.t() | nil  (DNS_CLUSTER_QUERY value)
Svmm.Config.ekv_data_dir(config)     # String.t()
Svmm.Config.cluster_size(config)     # integer()
Svmm.Config.ekv_shards(config)       # integer()
```

Note: `parse_file/1` and `parse_string/1` are public (`@doc false`) for testing.

---

## 5. Application Module (`Svmm.Application`)

Reads config, sets up Erlang distribution, optionally verifies no existing primary, then starts the appropriate supervision tree for the role.

```elixir
defmodule Svmm.Application do
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
```

### Supervision tree shape

`children_for_role/1` builds the child list based on role:

```elixir
def children_for_role(config) do
  role = Svmm.Config.node_role(config)

  [
    {Cluster.Supervisor, [topologies(config), [name: Svmm.ClusterSupervisor]]},
    {Phoenix.PubSub, name: Svmm.PubSub}
  ] ++ role_children(role, config)
end
```

**Primary children:**

```elixir
[
  {EKV, [name: :svmm_cluster, data_dir: ..., cluster_size: ..., shards: ...]},
  {DurableServer.Supervisor,
   name: Svmm.DurableServer.Supervisor,
   prefix: "svmm/",
   backend: {DurableServer.Backends.EKVStore, [name: :svmm_cluster, start: false]}}
]
```

**Replica children:**

```elixir
[
  {EKV, [name: :svmm_cluster, data_dir: ..., cluster_size: ..., shards: ...,
         mode: :observer, region: "replica", region_routing: ["default"]]}
]
```

### Post-start: `start_primary_services/0`

After the supervisor tree is started, primaries call:

```elixir
defp start_primary_services do
  {:ok, _} =
    DurableServer.Supervisor.ensure_started_child(
      Svmm.DurableServer.Supervisor,
      {Svmm.Hosts, key: Svmm.Hosts.topic(), initial_state: %{hosts: []}}
    )
end
```

This starts all domain DurableServer children (e.g. `Svmm.Hosts`). A failure to start any of them raises and aborts boot, so a primary never serves requests with missing domain servers. This two-phase approach (supervisor first, then `ensure_started_child`) is required because DurableServer children need the supervisor and EKV to be running first.

### libcluster topology

Replicas discover and connect to the primary using the `Cluster.Strategy.Epmd` strategy:

```elixir
defp topologies(config) do
  case Svmm.Config.primary_address(config) do
    nil -> []
    addr ->
      [
        svmm: [
          strategy: Cluster.Strategy.Epmd,
          config: [hosts: [:"primary@#{addr}"]]
        ]
      ]
  end
end
```

The primary **must** be named `primary@<IP>` — all replicas look for that exact node name via EPMD.

### Distribution setup

```elixir
defp setup_distribution(config) do
  node_name = Svmm.Config.node_name(config)
  cookie = Svmm.Config.cookie(config)

  if node_name && not Node.alive?() do
    case Node.start(node_name, name_domain: :longnames) do
      {:ok, _pid} -> Logger.info("Node started with name #{node_name}")
      {:error, {:already_started, _pid}} -> Logger.info("Node already started with name #{node_name}")
      {:error, reason} -> raise "Failed to start node: #{inspect(reason)}"
    end

    if cookie do
      Node.set_cookie(cookie)
    end
  end
end
```

### Primary uniqueness check

```elixir
def verify_no_existing_primary(config) do
  primary_address = Svmm.Config.primary_address(config)
  node_name = Svmm.Config.node_name(config) || Node.self()

  with true <- primary_address != nil,
       true <- Node.alive?(),
       primary_node = :"primary@#{primary_address}",
       true <- primary_node != node_name,
       :pong <- :net_adm.ping(primary_node) do
    raise "Another primary is already running at #{primary_node}. ..."
  else
    _ -> :ok
  end
end
```

Prevents split-brain by refusing to start a second primary when one is reachable.

### Architecture decisions

**Why `one_for_one`?** EKV, DurableServer.Supervisor, and the web endpoint are independent at the process level.

**Why no endpoint on replicas?** `SvmmWeb.Application` checks the role and only starts `SvmmWeb.Endpoint` and `SvmmWeb.Telemetry` on primaries. Replicas are headless — they only replicate data.

**Why `start_primary_services/0` after `Supervisor.start_link`?** DurableServer children need EKV to be running. Starting them post-supervision avoids a circular dependency in the child list.

---

## 6. Web Application (`SvmmWeb.Application`)

Role-aware: only starts the HTTP server and telemetry on primaries.

```elixir
defmodule SvmmWeb.Application do
  use Application

  @impl true
  def start(_type, _args) do
    config = Svmm.Config.load()

    children =
      if Svmm.Config.node_role(config) == :primary do
        [SvmmWeb.Telemetry, SvmmWeb.Endpoint]
      else
        []
      end

    opts = [strategy: :one_for_one, name: SvmmWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

---

## 7. EKV Configuration Details

EKV is an embedded distributed key-value store backed by SQLite.

- **Member mode**: Full read/write (primary)
- **Observer mode**: Read-only replica that receives writes from the primary via Erlang distribution

The EKV instance is registered as `:svmm_cluster` on all nodes. **Both primary and replica use the same default `EKV_DATA_DIR`.** In production, each node runs on a separate host so the same path (e.g. `./data/ekv_store`) points to a different filesystem. This makes promotion zero-effort: a replica restarted as primary already has the replicated data at the expected path. The only structural difference between roles is the `mode` option passed to EKV.

The local dev scripts use different directories (`ekv_store` vs `replica_ekv_store`) solely to avoid file conflicts when running two BEAM nodes on the same machine.

### Primary EKV config

```elixir
[
  name: :svmm_cluster,
  data_dir: "./data/ekv_store",   # same default path on every node
  cluster_size: 1,
  shards: 2
]
```

### Replica EKV config

```elixir
[
  name: :svmm_cluster,
  data_dir: "./data/ekv_store",   # same path — different filesystem in production
  cluster_size: 1,
  shards: 2,
  mode: :observer,
  region: "replica",
  region_routing: ["default"]
]
```

### Data directory structure

```
data/ekv_store/
  shard_0.db  shard_0.db-shm  shard_0.db-wal
  shard_1.db  shard_1.db-shm  shard_1.db-wal
```

Add `/data/` to `.gitignore`.

---

## 8. DurableServer Integration

DurableServer is a GenServer wrapper that persists state to EKV on every change, recovers state on restart, and supports state versioning.

### Supervisor config

```elixir
{DurableServer.Supervisor,
 name: Svmm.DurableServer.Supervisor,
 prefix: "svmm/",
 backend: {DurableServer.Backends.EKVStore, [name: :svmm_cluster, start: false]}}
```

- `name: Svmm.DurableServer.Supervisor` — registered name (used for `lookup` and `ensure_started_child`)
- `prefix: "svmm/"` — all EKV keys are namespaced under this prefix
- `start: false` — EKV is started separately in the supervision tree

### Domain module pattern

```elixir
defmodule Svmm.SomeDomain do
  use DurableServer, vsn: 1

  alias Phoenix.PubSub
  require Logger

  def topic, do: "svmm:some_domain"

  @impl true
  def init(state) do
    state = Map.merge(%{field: default}, state)
    {:ok, state, permanent: true, auto_sync: true}
  end

  @impl true
  def dump_state(state) do
    # Only persist desired/permanent fields; exclude transient runtime state
    %{field: state.field}
  end

  @impl true
  def load_state(_old_vsn, persisted_state), do: persisted_state

  # Public API
  def get_field do
    {pid, _meta} = DurableServer.Supervisor.lookup(Svmm.DurableServer.Supervisor, topic())
    GenServer.call(pid, :get_field)
  end
end
```

### Key callbacks

| Callback | Purpose |
|---|---|
| `dump_state(state)` | Returns the subset of state to persist. Exclude transient data (session counters, connection state, heartbeats). |
| `init(state)` | Receives persisted state (or `initial_state`). Merge with transient defaults and return `{:ok, state, opts}`. |
| `load_state(old_vsn, state)` | Migrate state from older `vsn` values. |

### Permanent vs transient data

- **Permanent** (persisted via `dump_state`): host definitions, VM specs, cluster membership, resource allocations, desired state
- **Transient** (excluded from `dump_state`): runtime status, heartbeat timestamps, active connections, computed values

### Starting domain children

Domain children are started post-supervisor via `start_primary_services/0`:

```elixir
DurableServer.Supervisor.ensure_started_child(
  Svmm.DurableServer.Supervisor,
  {Svmm.SomeDomain, key: Svmm.SomeDomain.topic(), initial_state: %{field: default}}
)
```

---

## 9. Domain Modules

### `Svmm.Hosts`

Manages the desired state of physical hosts.

```
topic: "svmm:hosts"
state: %{hosts: [hostname, ...]}
```

**Public API:**

```elixir
Svmm.Hosts.get_hosts()          # -> [String.t()]
Svmm.Hosts.add_host(hostname)   # -> :ok  (cast, async)
```

**Persistence:** only `%{hosts: [...]}` is persisted. The list is prepended on `add_host`.

---

## 10. Supervision Tree Summary

### Primary node

```
Svmm.Supervisor (one_for_one)
  +-- Cluster.Supervisor (name: Svmm.ClusterSupervisor)
  +-- Phoenix.PubSub (name: Svmm.PubSub)
  +-- EKV (name: :svmm_cluster, mode: member)
  +-- DurableServer.Supervisor (name: Svmm.DurableServer.Supervisor)
      +-- Svmm.Hosts  [started via start_primary_services/0]

SvmmWeb.Supervisor (one_for_one)
  +-- SvmmWeb.Telemetry
  +-- SvmmWeb.Endpoint
```

### Replica node

```
Svmm.Supervisor (one_for_one)
  +-- Cluster.Supervisor (name: Svmm.ClusterSupervisor)
  +-- Phoenix.PubSub (name: Svmm.PubSub)
  +-- EKV (name: :svmm_cluster, mode: observer)

SvmmWeb.Supervisor (one_for_one)
  [empty — no endpoint on replicas]
```

### How clustering works

1. Primary starts with `NODE_NAME=primary@<IP>` and `DNS_CLUSTER_QUERY=<IP>`
2. Replica starts with `NODE_NAME=replica@<IP>` and `DNS_CLUSTER_QUERY=<primary_IP>`
3. `Cluster.Strategy.Epmd` on the replica connects to `primary@<primary_IP>`
4. Once Erlang distribution connects the nodes, EKV observer mode automatically receives writes from the primary EKV member
5. `verify_no_existing_primary/1` on the primary prevents split-brain

### 10.1 Failover model: manual, by design

SVMM deliberately has **no automatic failover, quorum or leader election**. A customer runs one main server (primary) plus any number of replicas that hold a copy of the data. If the primary fails, the operator decides to promote a replica and starts it by hand with `NODE_ROLE=primary`.

Consequences:

- Replicas are cold standbys: headless, read-only EKV observers. Their only job is to keep a current copy of the state.
- Promotion is a restart with a different role. No data movement is needed because the replica's EKV directory already has the data.
- The operator is responsible for making sure the old primary is really down before promoting. `verify_no_existing_primary/1` is a safety net for that: it refuses to boot a second primary if one is reachable over Erlang distribution. It cannot detect a primary that is alive but partitioned away, and that case is left to the operator.
- The old primary must not be restarted as a primary after a promotion. Bring it back as a replica.
- Anything that depends on a replica being current (promotion runbook, UI) should show how fresh the copy is, because the operator decides based on it. This is not built yet.

The "relinquish the lead on quorum loss" wording in the parent `ARCHITECTURE.md` (§5) and the quorum/leader-election items in the root `AGENTS.md` do not apply to this model.

---

## 11. Scripts (`scripts/`)

All scripts use `SCRIPT_DIR` for portable relative paths. The dev cookie defaults to `svmm_dev`.

> **Note on EKV directories in these scripts:** In production each node is on a separate host, so primary and replica both use the same default path (`./data/ekv_store`). These scripts run two nodes on the same machine, so they use different directories to avoid SQLite file conflicts. That is the only reason the paths differ.

### `scripts/PRIMARY.sh`

```bash
#!/usr/bin/env bash
SCRIPT_DIR=$(dirname $(readlink -f "${BASH_SOURCE[0]}"))

export NODE_NAME="primary@127.0.0.1"
export EKV_DATA_DIR="$SCRIPT_DIR/../data/ekv_store"
export NODE_ROLE="primary"
export ERLANG_COOKIE="${ERLANG_COOKIE:-svmm_dev}"
export DNS_CLUSTER_QUERY="${DNS_CLUSTER_QUERY:-127.0.0.1}"

iex --name "$NODE_NAME" -S mix phx.server "$@"
```

### `scripts/REPLICA.sh`

```bash
#!/usr/bin/env bash
SCRIPT_DIR=$(dirname $(readlink -f "${BASH_SOURCE[0]}"))

export NODE_NAME="replica@127.0.0.1"
export PORT="4001"
export EKV_DATA_DIR="$SCRIPT_DIR/../data/replica_ekv_store"   # different dir: same-machine workaround
export NODE_ROLE="replica"
export ERLANG_COOKIE="${ERLANG_COOKIE:-svmm_dev}"
export DNS_CLUSTER_QUERY="${DNS_CLUSTER_QUERY:-127.0.0.1}"

iex --name "$NODE_NAME" -S mix phx.server "$@"
```

### `scripts/REPLICA_AS_PRIMARY.sh` (local failover simulation)

```bash
#!/usr/bin/env bash
SCRIPT_DIR=$(dirname $(readlink -f "${BASH_SOURCE[0]}"))

export NODE_NAME="primary@127.0.0.1"
export PORT="4002"
export EKV_DATA_DIR="$SCRIPT_DIR/../data/replica_ekv_store"   # points at replica's data dir
export NODE_ROLE="primary"
export ERLANG_COOKIE="${ERLANG_COOKIE:-svmm_dev}"
export DNS_CLUSTER_QUERY="${DNS_CLUSTER_QUERY:-127.0.0.1}"

iex --name "$NODE_NAME" -S mix phx.server "$@"
```

Simulates promoting a replica to primary on a single machine. In production, promotion is simply restarting the replica process with `NODE_ROLE=primary` — no data movement needed because the EKV path is already the same on every host.

### `scripts/CLEAN_STORAGE.sh`

Deletes both local test EKV data directories. Run between test sessions to start clean.

Make scripts executable: `chmod +x scripts/*.sh`

---

## 12. Manual Testing (`scripts/MANUAL_TESTING.md`)

### Scenario A — Single machine (two terminals)

**Terminal 1 — Primary:**

```bash
./scripts/PRIMARY.sh
```

Add data in iex:

```elixir
Svmm.Hosts.add_host("myserver.example.com")
Svmm.Hosts.get_hosts()
# => ["myserver.example.com"]
```

**Terminal 2 — Replica:**

```bash
./scripts/REPLICA.sh
```

Verify in replica iex:

```elixir
Node.list()
# => [:"primary@127.0.0.1"]

Svmm.Hosts.get_hosts()
# => ["myserver.example.com"]  (replicated via EKV observer)
```

Verify no web server on replica:

```bash
curl http://localhost:4001   # => connection refused
```

**Promote replica to primary** (after stopping the primary):

```bash
./scripts/REPLICA_AS_PRIMARY.sh
```

This script reads from the replica's separate local data dir (`data/replica_ekv_store`). In production on separate hosts, you would just restart the replica process with `NODE_ROLE=primary` — no data movement needed.

Verify data is intact and web UI available:

```elixir
Svmm.Hosts.get_hosts()
# => ["myserver.example.com"]
```

```bash
curl http://localhost:4002   # => HTTP 200
```

### Scenario B — Two machines

`DNS_CLUSTER_QUERY` points to the primary's IP. Both machines must have TCP open on:
- `4369` — epmd
- `9100–9155` — Erlang distribution (configure via `ELIXIR_ERL_OPTIONS="-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9155"`)

### Using `svmm.conf` files

```
# primary.conf
NODE_NAME=primary@127.0.0.1
NODE_ROLE=primary
ERLANG_COOKIE=svmm_dev
EKV_DATA_DIR=data/ekv_store
DNS_CLUSTER_QUERY=127.0.0.1
```

```
# replica.conf  (local testing — different EKV dir only because both nodes share the same machine)
NODE_NAME=replica@127.0.0.1
NODE_ROLE=replica
ERLANG_COOKIE=svmm_dev
EKV_DATA_DIR=data/replica_ekv_store
DNS_CLUSTER_QUERY=127.0.0.1
PORT=4001
```

In production the `EKV_DATA_DIR` line is omitted and defaults to `./data/ekv_store` on every host.

Copy or symlink to `./svmm.conf` before running. Environment variables override the file.

---

## 13. Testing

### `apps/svmm/test/test_helper.exs`

```elixir
ekv_dir = Application.get_env(:svmm, :ekv_data_dir)

if ekv_dir do
  File.rm_rf!(ekv_dir)
end

unless Node.alive?() do
  Node.start(:"test_node@127.0.0.1", name_domain: :longnames)
end

ExUnit.start()
```

Cleans the EKV test directory and starts Erlang distribution before each test run. Uses `name_domain: :longnames` (same as production).

### `apps/svmm/test/svmm/config_test.exs`

Tests `parse_string/1`, `node_role/1`, `node_name/1`, `cookie/1`, `ekv_data_dir/1`.

Key cases:
- Parses `KEY=value` pairs, skips blank lines and `#` comments
- Splits on the first `=` only (preserves `secret=with=equals`)
- Trims whitespace from keys and values
- `node_role/1` defaults to `:primary` for any value except `"replica"`
- `node_name/1` and `cookie/1` return `nil` for `nil` or `""`

### `apps/svmm/test/svmm/cluster_test.exs`

Tests the clustering infrastructure using `:peer` to start real BEAM nodes.

**`primary safety check`**

- Raises when `primary@127.0.0.1` is reachable and the config's `NODE_NAME` is different
- Succeeds when no primary is reachable (unreachable IP `192.0.2.99`)

**`supervision tree shape`**

- Primary: `children_for_role` includes `EKV` and `DurableServer.Supervisor`
- Replica: `children_for_role` includes `EKV` but not `DurableServer.Supervisor`

Note: `async: false` is required because distribution and `:peer` tests are not isolated.

---

## 14. Umbrella `mix.exs` Aliases

```elixir
defp aliases do
  [
    setup: ["deps.get", "assets.setup", "assets.build"],
    "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
    "assets.build": ["compile", "tailwind svmm_web", "esbuild svmm_web"],
    "assets.deploy": [
      "tailwind svmm_web --minify",
      "esbuild svmm_web --minify",
      "phx.digest"
    ],
    precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
  ]
end
```

Run `mix precommit` before committing. It compiles with warnings-as-errors, removes unused deps, formats code, and runs all tests.

---

## 15. `.gitignore` Additions

```
/data/
```

---

## 16. `.formatter.exs`

```elixir
[
  import_deps: [:phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}"]
]
```

---

## 17. Headless Mode

- **With web**: `iex -S mix phx.server` (starts both `:svmm` and `:svmm_web`)
- **Headless**: `iex -S mix` — `SvmmWeb.Application` starts with empty children; no HTTP server

Replicas are always headless by design (`SvmmWeb.Application` starts no children for `:replica`).

---

## 18. Version Reference

| Component | Version |
|---|---|
| Elixir | ~> 1.15 |
| Phoenix | ~> 1.8.8 |
| Phoenix LiveView | ~> 1.2.0 |
| Bandit | ~> 1.5 |
| DurableServer | ~> 0.1.4 |
| EKV | ~> 0.4.0 |
| libcluster | ~> 3.4 |
| esbuild | 0.25.4 |
| Tailwind CSS | 4.3.0 |

---

## 19. Adding New Domain Modules

1. Create `apps/svmm/lib/svmm/<domain>.ex` using `use DurableServer, vsn: 1`
2. Define `topic/0`, `init/1`, `dump_state/1`, `load_state/2`, and GenServer callbacks
3. Add `ensure_started_child` call in `Svmm.Application.start_primary_services/0`
4. Only include permanent (desired) state in `dump_state/1` — exclude runtime/transient fields
5. Broadcast changes via `Phoenix.PubSub` from within callbacks so LiveViews can react

See `Svmm.Hosts` as the reference implementation.

---

## 20. Authentication

See [`docs/Authentication.md`](../docs/Authentication.md) for the full design. This section covers the implementation structure within the umbrella.

### Auth behaviour (`apps/svmm/lib/svmm/auth.ex`)

```elixir
defmodule Svmm.Auth do
  @callback authenticate(credentials :: map()) :: {:ok, user :: map()} | {:error, atom()}
  @callback verify_agent_token(token :: String.t()) :: {:ok, agent_id :: String.t()} | :error

  def authenticate(credentials), do: backend().authenticate(credentials)
  def verify_agent_token(token), do: backend().verify_agent_token(token)
  defp backend, do: Application.get_env(:svmm, :auth_backend, Svmm.Auth.EKVBackend)
end
```

### EKV backend (`apps/svmm/lib/svmm/auth/ekv_backend.ex`)

Implements `Svmm.Auth`. Stores credentials in EKV under the `svmm/auth/` prefix.

EKV keys:

- `svmm/auth/users/<username>` → `%{password_hash: ..., roles: [...], created_at: ...}`
- `svmm/auth/agents/<agent_id>` → `%{token_hash: ..., created_at: ...}`

Exposes `bootstrap/0`, called from `start_primary_services/0`. It writes the initial admin password from `SVMM_ADMIN_PASSWORD` to EKV if no credentials exist yet. Bootstrap runs only on the primary; credentials replicate to replicas automatically via EKV observer mode.

### OIDC backend (`apps/svmm/lib/svmm/auth/oidc_backend.ex`)

Delegates user authentication to an external IdP. Agent token validation continues to use EKV. Enabled via `AUTH_BACKEND=oidc` in config/env.

### Session tokens

On successful user login, `SvmmWeb.Auth` issues a JWT signed with `SECRET_KEY_BASE`. Stored client-side (HttpOnly cookie). No server-side session storage required.

### Wiring bootstrap into `start_primary_services/0`

```elixir
defp start_primary_services do
  {:ok, _} =
    DurableServer.Supervisor.ensure_started_child(
      Svmm.DurableServer.Supervisor,
      {Svmm.Hosts, key: Svmm.Hosts.topic(), initial_state: %{hosts: []}}
    )

  :ok = Svmm.Auth.EKVBackend.bootstrap()
end
```

---

## 21. Agent Communication (transport-agnostic, WebSocket first)

SVMM talks to Go agents over a **transport-agnostic boundary** (ports & adapters).
The default adapter is **Phoenix Channels over WebSocket** — no message broker
required. A future **AMQP adapter** can be dropped in by config, without touching
the domain or adding an `amqp` dependency to the core.

### 21.1 Guiding principles

- **Core owns contracts, not transports.** `apps/svmm` depends on neither Phoenix
  (web) nor `amqp`. It ships a behaviour + canonical structs; every transport is an
  adapter that depends *on* the core, never the reverse.
- **Fire-and-forget is acceptable.** Commands and events may be lost on disconnect
  (at-most-once). No durable queue is built on the WebSocket path.
- **Two symmetric pipelines.** The inbound (agent → state/UI) path and the outbound
  (intent → command → agent) path both cross the same transport boundary, so a new
  transport lights up both directions at once.
- **Independent of the external Commanded/AMQP system.** SVMM never imports
  `commanded`. Integration happens later through an anti-corruption layer in its own
  app that maps the external system's events onto `Svmm.Agents` intents.

### 21.2 Tiers

```
API tier         apps/svmm_web  — REST/JSON + GraphQL controllers, LiveView UI
                      │ Svmm.Agents.command/2 (intent)        ▲ subscribes Svmm.PubSub
DECISION tier    apps/svmm      — Svmm.Orchestrator, Svmm.Hosts/DurableServer (EKV)
                      │ Svmm.Agents.Transport (behaviour)     ▲ Svmm.Agents.Ingress
EDGE/TRANSPORT   adapter apps   — WebSocket now (svmm_web); AMQP later (svmm_amqp)
                      ▲ WSS/443                               ▲ AMQPS/5671 (future)
                                        Go agents
```

Tiers are separate umbrella apps communicating through `Svmm.PubSub` and the
transport behaviour, so the **API tier** and **decision tier** can later be split
onto different libcluster nodes without code change (the role-aware
`SvmmWeb.Application` is the seam).

### 21.3 Core contracts (`apps/svmm`, no transport deps)

Canonical structs — the internal representation, independent of any wire format.
Every adapter marshals JSON/AMQP payloads to/from these; the domain never sees a
wire format.

```elixir
# apps/svmm/lib/svmm/agents/command.ex   (server → agent, outbound)
defmodule Svmm.Agents.Command do
  @enforce_keys [:action]
  defstruct [:action, params: %{}, id: nil]   # action: :start_vm | :stop_vm | :full_refresh
  @type t :: %__MODULE__{action: atom(), params: map(), id: String.t() | nil}
end

# apps/svmm/lib/svmm/agents/event.ex      (agent → server, inbound, normalized)
defmodule Svmm.Agents.Event do
  @enforce_keys [:kind, :agent_id]
  defstruct [:kind, :agent_id, payload: %{}, received_at: nil]  # kind: :registration | :heartbeat | :status
  @type t :: %__MODULE__{kind: atom(), agent_id: String.t(), payload: map(), received_at: DateTime.t() | nil}
end
```

The outbound **port** (behaviour) — the only thing the decision tier knows about
transport. Runtime dispatch via config avoids a compile-time core→adapter dep.

```elixir
# apps/svmm/lib/svmm/agents/transport.ex
defmodule Svmm.Agents.Transport do
  @callback send_command(agent_id :: String.t(), Svmm.Agents.Command.t()) :: :ok | {:error, term()}
  @callback connected?(agent_id :: String.t()) :: boolean()

  def impl, do: Application.fetch_env!(:svmm, :agent_transport)
  def send_command(agent_id, cmd), do: impl().send_command(agent_id, cmd)
  def connected?(agent_id), do: impl().connected?(agent_id)
end
```

The inbound **funnel** — a single door every adapter calls, so decision logic has
one entry point regardless of wire. (`Phoenix.PubSub` is a standalone lib, not the
web framework, so it is fine in core.)

```elixir
# apps/svmm/lib/svmm/agents/ingress.ex
defmodule Svmm.Agents.Ingress do
  @spec handle(Svmm.Agents.Event.t()) :: :ok
  def handle(%Svmm.Agents.Event{} = ev) do
    Svmm.Agents.Registry.touch(ev.agent_id)               # liveness, transport-agnostic
    Phoenix.PubSub.broadcast(Svmm.PubSub, "agents", ev)   # domain + LiveViews react
  end
end
```

Supporting core modules:
- `Svmm.Agents` — context facade; `command(agent_id, action, params)` builds a
  `%Command{}` and calls `Transport.send_command/2`. Public API for the API tier and orchestrator.
- `Svmm.Agents.Registry` — transport-agnostic agent liveness (who is connected /
  last seen), so the domain never queries `Presence` directly.
- `Svmm.Orchestrator` — decision tier: consumes the `"agents"` PubSub topic, decides,
  emits commands through the port.

### 21.4 WebSocket adapter (now, `apps/svmm_web`)

Endpoint socket:

```elixir
socket "/agent/socket", SvmmWeb.AgentSocket,
  websocket: [check_origin: false],
  longpoll: false
```

Auth stays in `SvmmWeb.AgentSocket` (token via `Svmm.Auth.verify_agent_token/1`):

```elixir
defmodule SvmmWeb.AgentSocket do
  use Phoenix.Socket
  channel "host:*", SvmmWeb.AgentChannel

  @impl true
  def connect(%{"token" => token}, socket, _info) do
    case Svmm.Auth.verify_agent_token(token) do
      {:ok, agent_id} -> {:ok, assign(socket, :agent_id, agent_id)}
      :error -> :error
    end
  end

  @impl true
  def id(socket), do: "agent_socket:#{socket.assigns.agent_id}"
end
```

`SvmmWeb.AgentChannel` is **thin** — it only marshals JSON → `%Event{}` and delegates
to the core funnel; no domain logic lives here:

```elixir
defmodule SvmmWeb.AgentChannel do
  use Phoenix.Channel
  alias Svmm.Agents.{Event, Ingress}

  def join("host:" <> agent_id, _params, socket) do
    {:ok, assign(socket, :agent_id, agent_id)}
  end

  def handle_in(kind, payload, socket) when kind in ~w(registration heartbeat status) do
    Ingress.handle(%Event{
      kind: String.to_existing_atom(kind),
      agent_id: socket.assigns.agent_id,
      payload: payload,
      received_at: DateTime.utc_now()
    })
    {:noreply, socket}
  end
end
```

Outbound adapter implements the behaviour:

```elixir
# apps/svmm_web/lib/svmm_web/agent_transport.ex
defmodule SvmmWeb.AgentTransport do
  @behaviour Svmm.Agents.Transport

  @impl true
  def send_command(agent_id, %Svmm.Agents.Command{} = c),
    do: SvmmWeb.Endpoint.broadcast("host:#{agent_id}", "command", to_wire(c))

  @impl true
  def connected?(agent_id), do: SvmmWeb.Presence.get_by_key("agents", agent_id) != []

  defp to_wire(%{action: a, params: p}), do: %{action: Atom.to_string(a), params: p}
end
```

Wiring:

```elixir
# config/config.exs
config :svmm, :agent_transport, SvmmWeb.AgentTransport
```

No extra supervisor child is needed on this path — Phoenix Channels are managed by
`SvmmWeb.Endpoint`.

### 21.5 AMQP adapter (future, `apps/svmm_amqp`)

Delivered as a **separate umbrella app** so `apps/svmm` never gains an `amqp`
dependency. It provides:
- `Svmm.Amqp.Consumer` — a `Broadway`/`amqp` consumer that marshals AMQP messages →
  `%Event{}` → `Svmm.Agents.Ingress.handle/1` (same funnel as WebSocket).
- `Svmm.Amqp.Transport` — implements `Svmm.Agents.Transport`, publishing `%Command{}`
  to an exchange.

Switching transports is then: add the app to the umbrella and flip one line —

```elixir
config :svmm, :agent_transport, Svmm.Amqp.Transport
```

Liveness on the AMQP path is heartbeat/TTL based via `Svmm.Agents.Registry` (no
`Presence`), keeping the domain unchanged.

### 21.6 External Commanded/AMQP integration (anti-corruption layer)

When integrating the external system that uses Commanded + AMQP, add
`apps/svmm_integration`. It translates *their* Commanded events / AMQP messages onto
`Svmm.Agents.command/2` and reads SVMM's `"agents"` PubSub events back. SVMM core
never imports `commanded`; the two systems meet only at this ACL, which can reuse the
`apps/svmm_amqp` transport.

### 21.7 Event reference

| Direction | Event / `kind` | Key payload fields |
|---|---|---|
| Agent → SVMM | `registration` | `agent_id`, `connection_type` (`"system"` \| `"user"`), `user` (user mode only) |
| Agent → SVMM | `heartbeat` | `agent_id`, `timestamp` |
| Agent → SVMM | `status` | `agent_id`, `vms`, `networks`, `node` |
| SVMM → Agent | `command` | `action` (`"start_vm"` \| `"stop_vm"` \| `"full_refresh"`), `params` |

See `amqp-libvirt-bridge/PROTOCOL.md` for full wire message formats including status
diff structure.

### 21.8 Migration steps (each shippable)

1. Add core contracts: `Command`, `Event`, `Transport` behaviour, `Ingress`,
   `Registry`, `Agents` facade (pure extraction, no behaviour change).
2. Refactor `AgentChannel` to marshal → `Ingress`; add `SvmmWeb.AgentTransport`;
   wire config. WebSocket keeps working, now behind the port.
3. Introduce `Svmm.Orchestrator` (decision tier) consuming `"agents"` PubSub,
   emitting commands via the port.
4. Add API-tier controllers calling `Svmm.Agents.command/2`.
5. *(Future)* `apps/svmm_amqp` adapter — flip config to switch transports.
6. *(Future)* `apps/svmm_integration` ACL for the external Commanded/AMQP system.
