#!/bin/bash
# Inject packet loss on a container's egress for a limited time.
# usage: netem_loss.sh <container> <loss_percent> <duration, e.g. 60s>
set -euo pipefail
C=${1:?container}; PCT=${2:?loss percent}; DUR=${3:?duration like 60s}
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock gaiaadm/pumba \
  netem --duration "$DUR" \
        --tc-image ghcr.io/alexei-led/pumba-alpine-nettools:latest \
        loss --percent "$PCT" "$C"
