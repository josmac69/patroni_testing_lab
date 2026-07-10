#!/bin/bash
# SCENARIO 04 - guided failsafe_mode comparison (Patroni >= 3.0).
#
# Runs the full DCS-quorum-loss experiment twice:
#   pass 1: failsafe_mode=false -> primary demotes, writes stop
#   pass 2: failsafe_mode=true  -> primary keeps accepting writes
#
# Expert caveat worth mentioning in a talk: the failsafe member check uses a
# hardcoded 2-second timeout per member, so on high-latency links the safety
# net may fail to engage even though all members are alive.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

run_pass() {
    local mode="$1"
    banner "PASS: failsafe_mode=$mode"
    patronictl \
        edit-config --force -s "failsafe_mode=$mode"
    sleep 12   # let the config propagate on the next HA loop

    banner "stopping etcd2 + etcd3 (quorum loss)"
    docker compose stop etcd2 etcd3
    sleep 45   # > ttl, enough for demotion to happen if it is going to

    if leader=$(current_leader); then
        echo "RESULT: leader $leader still serving writes (failsafe kept it up)"
    else
        echo "RESULT: no writable leader - primary demoted to read-only"
    fi

    banner "recovering etcd"
    docker compose start etcd2 etcd3
    sleep 20
    cluster_list
}

run_pass false
run_pass true

banner "cleanup: leaving failsafe_mode=false (lab default)"
patronictl \
    edit-config --force -s "failsafe_mode=false"
