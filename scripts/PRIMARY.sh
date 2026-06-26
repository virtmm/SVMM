#!/usr/bin/env bash

SCRIPT_DIR=$(dirname $(readlink -f "${BASH_SOURCE[0]}"))

export NODE_NAME="primary@127.0.0.1"
export EKV_DATA_DIR="$SCRIPT_DIR/../data/ekv_store"
export NODE_ROLE="primary"
export ERLANG_COOKIE="${ERLANG_COOKIE:-svmm_dev}"
export DNS_CLUSTER_QUERY="${DNS_CLUSTER_QUERY:-127.0.0.1}"

iex --name "$NODE_NAME" -S mix phx.server "$@"
