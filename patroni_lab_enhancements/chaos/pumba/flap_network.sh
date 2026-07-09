#!/bin/bash
# Repeated short disconnect/reconnect cycles - tests hysteresis of Patroni
# timers and HAProxy rise/fall settings against link flapping.
# usage: flap_network.sh <container> <cycles> [down_seconds=5] [up_seconds=10]
set -euo pipefail
C=${1:?container}; N=${2:?cycles}; DOWN=${3:-5}; UP=${4:-10}
NET=patroni_labnet
for i in $(seq 1 "$N"); do
    echo "cycle $i/$N: down ${DOWN}s"
    docker network disconnect "$NET" "$C"
    sleep "$DOWN"
    docker network connect "$NET" "$C"
    echo "cycle $i/$N: up ${UP}s"
    sleep "$UP"
done
