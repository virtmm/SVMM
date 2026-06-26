#!/usr/bin/env bash
SCRIPT_DIR=$(dirname $(readlink -f "${BASH_SOURCE[0]}"))
DATA_DIR="$SCRIPT_DIR/../data/ekv_store"
REPLICA_DATA_DIR="$SCRIPT_DIR/../data/replica_ekv_store"
echo "Deleting $DATA_DIR"
rm -rf "$DATA_DIR"
echo "Deleting $REPLICA_DATA_DIR"
rm -rf "$REPLICA_DATA_DIR"
