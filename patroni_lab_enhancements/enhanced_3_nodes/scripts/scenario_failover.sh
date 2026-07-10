#!/bin/bash
# SCENARIO 01 - hard leader crash and automatic failover.
#
# What it demonstrates:
#   * leader key expiry in etcd after ttl (default 30s)
#   * leader race among replicas, maximum_lag_on_failover filtering
#   * HAProxy write endpoint converging on the new primary
#   * the old timeline diverging -> healed later by pg_rewind
#
# Suggested companion: run `make measure-rpo-rto` in another terminal first,
# with the async profile, and compare against the quorum profile.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

leader=$(current_leader) || { err "No leader found"; exit 1; }
banner "current leader is $leader - state before the crash"
cluster_list

banner "killing $leader with SIGKILL (no clean shutdown, no final checkpoint)"
docker compose kill "$leader"
t0=$(date +%s)

banner "waiting for a new leader (expected within ttl + loop_wait, watch Grafana)"
new_leader=""
for i in $(seq 1 60); do
    if new_leader=$(current_leader) && [[ "$new_leader" != "$leader" ]]; then
        success "New leader elected: $new_leader!"
        break
    fi
    info "Waiting for election... (elapsed: ${i}s)"
    sleep 1
done
t1=$(date +%s)
[[ -n "$new_leader" ]] || { err "No new leader elected"; exit 1; }

banner "new leader: $new_leader after $((t1 - t0))s (REST-level detection)"
cluster_list

banner "restarting the old leader $leader - watch it rejoin as a replica"
docker compose start "$leader"
sleep 15
cluster_list
echo
info "Check the logs of $leader for 'pg_rewind' or a fresh basebackup:"
info "  docker compose logs $leader | grep -iE 'rewind|basebackup' | tail"
