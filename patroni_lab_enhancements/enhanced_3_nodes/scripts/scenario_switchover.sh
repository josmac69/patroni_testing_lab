#!/bin/bash
# SCENARIO 02 - clean, planned switchover.
#
# Contrast with scenario 01: Patroni checkpoints and demotes the old leader
# first, then promotes the candidate. Expected RPO is zero even in the
# asynchronous profile; RTO is typically 1-3 seconds plus HAProxy detection.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

banner "state before switchover"
cluster_list

leader=$(current_leader)
banner "switching over away from $leader"
docker compose exec -T patroni1 \
    patronictl -c /tmp/patroni.yml switchover --leader "$leader" --force

sleep 5
banner "state after switchover"
cluster_list
