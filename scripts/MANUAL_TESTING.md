# Primary / Replica Manual Testing Guide

This guide explains how to manually test the primary/replica flow — starting a PRIMARY, verifying a REPLICA syncs to it, and promoting the REPLICA to PRIMARY.

---

## Background: how nodes find each other

`DNSCluster` is configured with `basename: "primary"`. It resolves the address in `DNS_CLUSTER_QUERY` and tries to connect to the node named `primary@<that_address>`. This is why the PRIMARY node **must** be named `primary@<IP>` — it is the node name that all replicas look for.

---

## Scenario A — Single Machine (two terminals)

Two Erlang nodes run on `127.0.0.1` with different short names. The REPLICA's DNSCluster resolves `127.0.0.1` and connects to the already-running `primary@127.0.0.1`.

### Prerequisites

- Erlang/Elixir installed, `mix deps.get` done.
- `epmd` is started automatically by iex when you pass `--name`.

### Step 1 — Start the PRIMARY

```bash
./scripts/PRIMARY.sh
```

This starts `primary@127.0.0.1` on port **4000** with `NODE_ROLE=primary`.

In the iex shell, add some data:

```elixir
Svmm.Hosts.add_host("myserver.example.com")
Svmm.Hosts.add_host("otherserver.example.com")
Svmm.Hosts.get_hosts()
# => ["myserver.example.com", "otherserver.example.com"]
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

This starts `replica@127.0.0.1` on port **4001** with `NODE_ROLE=replica`.

Watch the PRIMARY terminal — you should see a log line from DNSCluster indicating `replica@127.0.0.1` connected.

In the REPLICA's iex shell, verify:

```elixir
# The primary is visible
Node.list()
# => [:"primary@127.0.0.1"]

# Data is replicated from primary (EKV observer mode)
Svmm.Hosts.get_hosts()
# => ["myserver.example.com", "otherserver.example.com"]
```

Verify the REPLICA has **no web server**:

```bash
curl http://localhost:4001
# => connection refused
```

### Step 3 — Promote the REPLICA to PRIMARY

Stop the PRIMARY with `Ctrl+C Ctrl+C` in terminal 1.

In a third terminal (or reuse terminal 1):

```bash
./scripts/REPLICA_AS_PRIMARY.sh
```

This starts as `primary@127.0.0.1` on port **4002**, using the replica's data directory.

Verify the data is intact:

```elixir
Svmm.Hosts.get_hosts()
# => ["myserver.example.com", "otherserver.example.com"]
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
| `Svmm.Hosts.get_hosts()` on both nodes | same list |
| `curl localhost:4002` after promotion | HTTP 200 |

---

## Scenario B — Two Machines

`DNS_CLUSTER_QUERY` points to the PRIMARY's IP. DNSCluster on the REPLICA resolves that IP and connects to `primary@<primary_IP>`.

### Machine A — PRIMARY

```bash
export NODE_NAME="primary@<machine_A_IP>"
export DNS_CLUSTER_QUERY="<machine_A_IP>"
export ERLANG_COOKIE="svmm_prod"
export EKV_DATA_DIR="/var/lib/svmm/ekv_store"
iex --name "$NODE_NAME" -S mix phx.server
```

Or create a `primary.conf` file (see below) and use `./scripts/PRIMARY.sh`.

### Machine B — REPLICA

```bash
export NODE_NAME="replica@<machine_B_IP>"
export DNS_CLUSTER_QUERY="<machine_A_IP>"   # points to primary's IP
export ERLANG_COOKIE="svmm_prod"            # must match primary
export EKV_DATA_DIR="/var/lib/svmm/replica_ekv_store"
export PORT="4001"
iex --name "$NODE_NAME" -S mix phx.server
```

### Firewall requirements

Both machines must allow TCP on:
- `4369` — epmd (Erlang Port Mapper Daemon)
- `9100–9155` — Erlang distribution (or configure a fixed range via `ELIXIR_ERL_OPTIONS="-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9155"`)

### Promoting Machine B to PRIMARY

Stop the PRIMARY on Machine A, then on Machine B:

```bash
export NODE_NAME="primary@<machine_B_IP>"
export DNS_CLUSTER_QUERY="<machine_B_IP>"
export NODE_ROLE="primary"
export ERLANG_COOKIE="svmm_prod"
export EKV_DATA_DIR="/var/lib/svmm/replica_ekv_store"  # same dir as replica
export PORT="4000"
iex --name "$NODE_NAME" -S mix phx.server
```

Update DNS or your load balancer so clients point to Machine B.

---

## Using `svmm.conf` files instead of env vars

The application reads `./svmm.conf` or `/etc/svmm.conf` automatically. You can create per-role config files for repeatable local testing.

**`primary.conf`**:
```
NODE_NAME=primary@127.0.0.1
NODE_ROLE=primary
ERLANG_COOKIE=svmm_dev
EKV_DATA_DIR=data/ekv_store
DNS_CLUSTER_QUERY=127.0.0.1
```

**`replica.conf`**:
```
NODE_NAME=replica@127.0.0.1
NODE_ROLE=replica
ERLANG_COOKIE=svmm_dev
EKV_DATA_DIR=data/replica_ekv_store
DNS_CLUSTER_QUERY=127.0.0.1
PORT=4001
```

Copy the desired file to `./svmm.conf` before running, or symlink it:

```bash
cp primary.conf svmm.conf && iex -S mix phx.server
# in another terminal:
cp replica.conf svmm.conf && iex -S mix phx.server
```

Environment variables override the file, so you can also override individual values:

```bash
PORT=4001 DNS_CLUSTER_QUERY=192.168.1.10 iex -S mix phx.server
```

---

## Cleaning up

To reset all stored data between test runs:

```bash
./scripts/CLEAN_STORAGE.sh
```
