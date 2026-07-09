#!/bin/bash
# Block until the cluster has a leader and all three members are registered.
# Used by `make up` and by CI.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

echo "waiting for a leader..."
for i in $(seq 1 60); do
    if leader=$(current_leader); then
        echo "leader: $leader (after ${i} attempts)"
        cluster_list
        exit 0
    fi
    sleep 2
done
echo "cluster did not converge within 120s" >&2
cluster_list || true
exit 1
