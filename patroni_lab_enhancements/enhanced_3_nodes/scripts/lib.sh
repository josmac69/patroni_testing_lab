#!/bin/bash
# Shared helpers for scenario scripts.
set -euo pipefail

PATRONI_NODES=(patroni1 patroni2 patroni3)
ETCD_NODES=(etcd1 etcd2 etcd3)

# Return the container name of the current leader by asking each REST API.
current_leader() {
    for node in "${PATRONI_NODES[@]}"; do
        code=$(docker compose exec -T "$node" \
            curl -s -o /dev/null -w '%{http_code}' http://localhost:8008/primary \
            2>/dev/null || echo 000)
        if [[ "$code" == "200" ]]; then
            echo "$node"
            return 0
        fi
    done
    return 1
}

cluster_list() {
    docker compose exec -T patroni1 patronictl -c /tmp/patroni.yml list 2>/dev/null \
      || docker compose exec -T patroni2 patronictl -c /tmp/patroni.yml list 2>/dev/null \
      || docker compose exec -T patroni3 patronictl -c /tmp/patroni.yml list
}

banner() {
    echo
    echo "== $* =="
}
