#!/bin/bash
# Add egress latency to a container for a limited time.
# usage: netem_delay.sh <container> <delay_ms> <duration, e.g. 60s>
set -euo pipefail
C=${1:?container}; MS=${2:?delay ms}; DUR=${3:?duration like 60s}
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock gaiaadm/pumba \
  netem --duration "$DUR" \
        --tc-image ghcr.io/alexei-led/pumba-alpine-nettools:latest \
        delay --time "$MS" --jitter $((MS / 5)) "$C"
