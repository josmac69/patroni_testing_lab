#!/bin/bash
# SCENARIO 05 - network partition of the leader.
#
# Unlike a crash, the partitioned leader keeps running - it just cannot
# reach etcd or the other members. What must happen:
#   * partitioned leader: cannot refresh the leader key -> demotes itself
#     to read-only within ttl. This is the split-brain protection.
#   * majority side: leader key expires -> one replica promotes.
#   * heal: the ex-leader returns with a diverged (or stale) timeline and
#     Patroni heals it with pg_rewind (use_pg_rewind: true, wal_log_hints on).
#
# For graduated partitions (latency, packet loss, asymmetry) see ../chaos/.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

STATE_FILE=/tmp/patroni_lab_partitioned_node

case "${1:-}" in
  partition)
    leader=$(current_leader) || { err "No leader found"; exit 1; }
    banner "disconnecting $leader from patroni_labnet"
    echo "$leader" > "$STATE_FILE"
    docker network disconnect patroni_labnet "$leader"
    banner "watching for promotion on the majority side"
    for i in $(seq 1 15); do
        sleep 4
        if new=$(current_leader) && [[ "$new" != "$leader" ]]; then
            success "t+$((i*4))s: new leader is $new"
            cluster_list
            exit 0
        fi
        info "t+$((i*4))s: no new leader yet"
    done
    err "no promotion observed - inspect logs" >&2
    exit 1
    ;;
  heal)
    node=$(cat "$STATE_FILE" 2>/dev/null) || { err "nothing partitioned"; exit 1; }
    banner "reconnecting $node"
    docker network connect patroni_labnet "$node"
    sleep 20
    cluster_list
    echo
    info "Inspect the healing path:"
    info "  docker compose logs $node | grep -iE 'rewind|demot|follow' | tail -20"
    rm -f "$STATE_FILE"
    ;;
  *)
    err "usage: $0 {partition|heal}" >&2
    exit 2
    ;;
esac
