#!/bin/bash
# SCENARIO 06 - reinitialize a broken replica.
#
# Simulates operator-grade replica damage and shows `patronictl reinit`,
# which wipes the data directory and re-clones from the leader. In the
# pgBackRest extension (../backup_pgbackrest) the same reinit restores from
# the backup repository instead, sparing the primary the basebackup load.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

leader=$(current_leader) || { err "No leader found"; exit 1; }
info "Current leader is $leader"
for node in "${PATRONI_NODES[@]}"; do
    [[ "$node" != "$leader" ]] && { victim=$node; break; }
done
info "Selected victim replica for failure simulation: $victim"

banner "victim replica: $victim - deleting pg_control to break it"
docker compose exec -T "$victim" bash -c \
    'rm -f /var/lib/postgresql/data/pgdata/global/pg_control' < /dev/null
docker compose restart "$victim"
sleep 10
cluster_list

banner "reinitializing $victim from the leader"
SCOPE="${CLUSTER_SCOPE:-lab}"
patronictl \
    reinit "$SCOPE" "$victim" --force
sleep 20
cluster_list
