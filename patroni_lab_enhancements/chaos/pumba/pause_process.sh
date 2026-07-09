#!/bin/bash
# Freeze (SIGSTOP) an entire container for a limited time - the "hung node"
# failure class, distinct from a crash. This is the watchdog's raison d'etre.
# usage: pause_process.sh <container> <duration, e.g. 60s>
set -euo pipefail
C=${1:?container}; DUR=${2:?duration like 60s}
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock gaiaadm/pumba \
  pause --duration "$DUR" "$C"
