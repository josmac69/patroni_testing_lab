#!/bin/bash
# SCENARIO 03 - DCS degradation vs DCS quorum loss.
#
# This distinction is exactly what a single-etcd lab cannot show:
#
#   degraded : stop 1 of 3 etcd members. etcd keeps quorum (2/3), Patroni
#              does not even notice. Nothing happens. That is the point.
#
#   lost     : stop 2 of 3. etcd loses quorum, all reads/writes to the DCS
#              fail. Patroni can no longer refresh the leader key, so with
#              failsafe_mode=false the primary DEMOTES ITSELF to read-only
#              within ttl seconds (default 30). This is the availability
#              price of the safety guarantee against split-brain.
#
#              With failsafe_mode=true (make failsafe-on) the leader instead
#              polls all members over the REST API (POST /failsafe); as long
#              as every member is reachable it keeps running as primary.
#
#   recover  : restart all etcd members.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

case "${1:-}" in
  degraded)
    banner "stopping etcd3 (1 of 3) - quorum holds, expect no impact"
    docker compose stop etcd3
    sleep 12
    cluster_list
    echo "Writes still work: psql -h localhost -p 5000 -U postgres -c 'select 1'"
    ;;
  lost)
    banner "stopping etcd2 and etcd3 (2 of 3) - quorum LOST"
    echo "Current failsafe_mode setting:"
    patronictl show-config \
      | grep -i failsafe || echo "  failsafe_mode: not set (defaults to false)"
    docker compose stop etcd2 etcd3
    banner "watching for up to 60s - with failsafe off, expect demotion within ttl"
    for i in $(seq 1 12); do
        sleep 5
        if leader=$(current_leader); then
            echo "t+$((i*5))s: leader still $leader (failsafe active?)"
        else
            echo "t+$((i*5))s: NO leader answering /primary - primary demoted, cluster read-only"
        fi
    done
    echo
    echo "Verify read-only:  psql -h localhost -p 5000 ... -> connection refused/failed"
    echo "Reads still fine:  psql -h localhost -p 5001 -U postgres -c 'select 1'"
    ;;
  recover)
    banner "restarting all etcd members"
    docker compose start etcd1 etcd2 etcd3
    sleep 15
    cluster_list
    ;;
  *)
    echo "usage: $0 {degraded|lost|recover}" >&2
    exit 2
    ;;
esac
