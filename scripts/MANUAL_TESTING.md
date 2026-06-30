# Primary / Replica Manual Testing Guide

This guide explains how to manually test the primary/replica flow — starting a PRIMARY, verifying a REPLICA syncs to it, and promoting the REPLICA to PRIMARY.

---

## Background: how nodes find each other

Node discovery uses **libcluster** with the `Cluster.Strategy.Epmd` strategy. On startup, each node reads `DNS_CLUSTER_QUERY` (the IP address of the machine running the PRIMARY) and tries to connect to the Erlang node named `primary@<that_address>`. This is why the PRIMARY node **must** be named `primary@<IP>` — it is the exact node name that all replicas look for.

The `Svmm.Application` also runs a safety check on startup: if a node tries to start as PRIMARY but finds another PRIMARY already reachable at that address, it raises an error and refuses to start. Stop the existing PRIMARY before promoting a replica.

---

## Scenario A — Single Machine (two terminals)

Two Erlang nodes run on `127.0.0.1` with different node names. `DNS_CLUSTER_QUERY` defaults to `127.0.0.1`, so the REPLICA's cluster strategy connects to the already-running `primary@127.0.0.1`.

### Prerequisites

- Erlang/Elixir installed, `mix deps.get` done, run from the umbrella root.
- `epmd` starts automatically when you pass `--name` to `iex`.

### Step 1 — Start the PRIMARY

```bash
./scripts/PRIMARY.sh
```

This exports:

| Variable | Value |
|----------|-------|
| `NODE_NAME` | `primary@127.0.0.1` |
| `NODE_ROLE` | `primary` |
| `EKV_DATA_DIR` | `<repo>/data/ekv_store` |
| `DNS_CLUSTER_QUERY` | `127.0.0.1` |
| `ERLANG_COOKIE` | `svmm_dev` |

The Phoenix web server starts on **port 4000**.

In the iex shell, add some data:

```elixir
Svmm.Hosts.add_host("myserver.example.com")
Svmm.Hosts.add_host("otherserver.example.com")
Svmm.Hosts.get_hosts()
# => ["otherserver.example.com", "myserver.example.com"]
```

Verify no other node is connected yet:

```elixir
Node.list()
# => []
```

### Step 2 — Start the REPLICA

In a second terminal:

```bash
./scripts/REPLICA.sh
```

This exports:

| Variable | Value |
|----------|-------|
| `NODE_NAME` | `replica@127.0.0.1` |
| `NODE_ROLE` | `replica` |
| `EKV_DATA_DIR` | `<repo>/data/replica_ekv_store` |
| `DNS_CLUSTER_QUERY` | `127.0.0.1` |
| `ERLANG_COOKIE` | `svmm_dev` |
| `PORT` | `4001` (configured but web server does not start) |

Watch the PRIMARY terminal — libcluster logs when `replica@127.0.0.1` connects.

In the REPLICA's iex shell, verify the cluster connection:

```elixir
Node.list()
# => [:"primary@127.0.0.1"]
```

Verify EKV data is being replicated (the REPLICA runs EKV in observer mode and syncs locally):

```elixir
EKV.scan(:svmm_cluster, "") |> Enum.to_list()
# => a list containing the hosts entries written on the primary
```

> **Note:** `Svmm.Hosts.get_hosts()` only works on the PRIMARY because `DurableServer.Supervisor` is not started on replicas. Use `EKV.scan/2` to verify replication on the replica side.

Verify the REPLICA has **no web server**:

```bash
curl http://localhost:4001
# => connection refused
```

### Step 3 — Promote the REPLICA to PRIMARY

Stop the PRIMARY with `Ctrl+C Ctrl+C` in terminal 1.

> Wait a moment for the PRIMARY node to fully shut down before starting `REPLICA_AS_PRIMARY.sh`. The startup safety check will refuse to start if it can still reach `primary@127.0.0.1`.

In a third terminal (or reuse terminal 1):

```bash
./scripts/REPLICA_AS_PRIMARY.sh
```

This exports:

| Variable | Value |
|----------|-------|
| `NODE_NAME` | `primary@127.0.0.1` |
| `NODE_ROLE` | `primary` |
| `EKV_DATA_DIR` | `<repo>/data/replica_ekv_store` (same dir as replica) |
| `DNS_CLUSTER_QUERY` | `127.0.0.1` |
| `PORT` | `4002` |

Verify the data is intact (loaded from the replica's EKV store):

```elixir
Svmm.Hosts.get_hosts()
# => ["otherserver.example.com", "myserver.example.com"]
```

Verify the web UI is now available:

```bash
curl http://localhost:4002
# => HTTP 200 with the Phoenix app
```

### What success looks like

| Check | Expected |
|-------|----------|
| `Node.list()` on REPLICA after startup | `[:"primary@127.0.0.1"]` |
| `curl localhost:4001` (while REPLICA is running) | `connection refused` |
| `EKV.scan(:svmm_cluster, "")` on REPLICA | contains hosts entries |
| `Svmm.Hosts.get_hosts()` on promoted PRIMARY | same list as original PRIMARY |
| `curl localhost:4002` after promotion | HTTP 200 |

---

## Scenario B — Two Machines

`DNS_CLUSTER_QUERY` on the REPLICA points to the PRIMARY's IP. Libcluster resolves the Epmd host `primary@<primary_IP>` and connects to it.

> **Dev-mode network note:** In `MIX_ENV=dev` the Phoenix endpoint binds to `127.0.0.1` only. The HTTP web UI checks below must be done from the same machine that runs the node. Erlang distribution traffic (clustering) works across machines regardless.

### Prerequisites

- Both machines have Elixir/Erlang installed and `mix deps.get` done.
- Both machines use the **same Erlang cookie**.
- Both machines can reach each other on:
  - `4369/tcp` — epmd (Erlang Port Mapper Daemon)
  - `9100–9155/tcp` — Erlang distribution (configure a fixed range via `ELIXIR_ERL_OPTIONS="-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9155"`)

### Machine A — PRIMARY

```bash
export NODE_NAME="primary@<machine_A_IP>"
export NODE_ROLE="primary"
export DNS_CLUSTER_QUERY="<machine_A_IP>"
export ERLANG_COOKIE="svmm_prod"
export EKV_DATA_DIR="/var/lib/svmm/ekv_store"

./scripts/PRIMARY.sh
```

`DNS_CLUSTER_QUERY` must equal the IP embedded in `NODE_NAME` so that the safety check (`verify_no_existing_primary`) and the cluster topology both use the correct address.

Add data in the iex shell:

```elixir
Svmm.Hosts.add_host("myserver.example.com")
Svmm.Hosts.add_host("otherserver.example.com")
Svmm.Hosts.get_hosts()
# => ["otherserver.example.com", "myserver.example.com"]
```

Verify the web UI (on Machine A):

```bash
curl http://localhost:4000
# => HTTP 200
```

### Machine B — REPLICA

```bash
export NODE_NAME="replica@<machine_B_IP>"
export NODE_ROLE="replica"
export DNS_CLUSTER_QUERY="<machine_A_IP>"   # points to primary's IP
export ERLANG_COOKIE="svmm_prod"            # must match Machine A
export EKV_DATA_DIR="/var/lib/svmm/replica_ekv_store"

./scripts/REPLICA.sh
```

Verify cluster connection (in Machine B's iex shell):

```elixir
Node.list()
# => [:"primary@<machine_A_IP>"]
```

Verify EKV replication:

```elixir
EKV.scan(:svmm_cluster, "") |> Enum.to_list()
# => contains the hosts entries
```

### Promoting Machine B to PRIMARY

Stop the PRIMARY on Machine A (`Ctrl+C Ctrl+C`). Wait for it to shut down, then on Machine B:

```bash
export NODE_NAME="primary@<machine_B_IP>"
export NODE_ROLE="primary"
export DNS_CLUSTER_QUERY="<machine_B_IP>"
export ERLANG_COOKIE="svmm_prod"
export EKV_DATA_DIR="/var/lib/svmm/replica_ekv_store"  # same dir as replica
export PORT="4000"

./scripts/REPLICA_AS_PRIMARY.sh
```

Verify data and web UI (on Machine B):

```elixir
Svmm.Hosts.get_hosts()
# => ["otherserver.example.com", "myserver.example.com"]
```

```bash
curl http://localhost:4000
# => HTTP 200
```

Update DNS or your load balancer so clients point to Machine B's IP.

---

## Using `svmm.conf` files instead of env vars

The application reads `./svmm.conf` or `/etc/svmm.conf` at startup (dotenv-style format, compatible with systemd `EnvironmentFile`). Environment variables override file values.

All recognised keys:

| Key | Description | Default |
|-----|-------------|---------|
| `NODE_NAME` | Long Erlang node name (e.g. `primary@127.0.0.1`) | none |
| `NODE_ROLE` | `primary` or `replica` | `primary` |
| `ERLANG_COOKIE` | Shared secret for Erlang distribution | none |
| `EKV_DATA_DIR` | Path to the EKV on-disk store | `data/ekv_store` |
| `DNS_CLUSTER_QUERY` | IP address of the PRIMARY node | none |
| `CLUSTER_SIZE` | Number of EKV voting members | `1` |
| `EKV_SHARDS` | Number of EKV shards | `2` |

Example `primary.conf`:

```
NODE_NAME=primary@127.0.0.1
NODE_ROLE=primary
ERLANG_COOKIE=svmm_dev
EKV_DATA_DIR=data/ekv_store
DNS_CLUSTER_QUERY=127.0.0.1
```

Example `replica.conf`:

```
NODE_NAME=replica@127.0.0.1
NODE_ROLE=replica
ERLANG_COOKIE=svmm_dev
EKV_DATA_DIR=data/replica_ekv_store
DNS_CLUSTER_QUERY=127.0.0.1
PORT=4001
```

Individual values can still be overridden at runtime:

```bash
DNS_CLUSTER_QUERY=192.168.1.10 ./scripts/REPLICA.sh
```

---

## Cleaning up

To reset all stored data between test runs:

```bash
./scripts/CLEAN_STORAGE.sh
```

This deletes `data/ekv_store` and `data/replica_ekv_store`.
