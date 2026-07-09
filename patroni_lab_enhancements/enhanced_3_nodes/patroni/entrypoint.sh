#!/bin/bash
# Render /etc/patroni.yml from the template using the node name injected by
# docker-compose, then start Patroni in the foreground.
set -euo pipefail

: "${PATRONI_NAME:?PATRONI_NAME must be set}"
: "${PATRONI_SCOPE:=lab}"

sed -e "s/__NODE_NAME__/${PATRONI_NAME}/g" \
    -e "s/__SCOPE__/${PATRONI_SCOPE}/g" \
    /etc/patroni.yml.tmpl > /tmp/patroni.yml

exec patroni /tmp/patroni.yml
