#!/bin/bash
# Shared helpers for scenario scripts.
set -euo pipefail

PATRONI_NODES=(patroni1 patroni2 patroni3)
ETCD_NODES=(etcd1 etcd2 etcd3)

# Return the container name of the current leader by asking each REST API.
current_leader() {
    for node in "${PATRONI_NODES[@]}"; do
        code=$(timeout 3 docker compose exec -T "$node" \
            curl -s -o /dev/null -w '%{http_code}' http://localhost:8008/primary \
            2>/dev/null || echo 000)
        if [[ "$code" == "200" ]]; then
            echo "$node"
            return 0
        fi
    done
    return 1
}
# Execute a patronictl command on a running Patroni node dynamically.
# Falls back to patroni1 if no running node is found.
patronictl() {
    local running_node
    running_node=$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'patroni[1-3]' | head -n 1)
    if [[ -z "$running_node" ]]; then
        running_node="patroni1"
    fi
    docker compose exec -T "$running_node" patronictl -c /tmp/patroni.yml "$@"
}

cluster_list() {
    local running_node
    running_node=$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'patroni[1-3]' | head -n 1)
    if [[ -z "$running_node" ]]; then
        running_node="patroni1"
    fi
    timeout 5 docker compose exec -T "$running_node" patronictl -c /tmp/patroni.yml list
}

banner() {
    echo
    echo "== $* =="
}
