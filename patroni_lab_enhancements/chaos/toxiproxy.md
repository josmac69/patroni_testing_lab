# Toxiproxy variant — per-connection fault injection

Pumba's netem faults affect a container's entire egress. To break **only**
the Patroni→etcd path while leaving streaming replication healthy (or the
reverse), route the specific connection through Toxiproxy.

## Setup

Add to the enhanced lab's `docker-compose.yml`:

    toxiproxy:
      image: ghcr.io/shopify/toxiproxy:2.9.0
      networks: [labnet]
      ports: ["8474:8474"]   # admin API

Point ONE Patroni node's DCS connection at the proxy instead of etcd
directly — in the compose service for e.g. `patroni2`:

    environment:
      PATRONI_ETCD3_HOSTS: "toxiproxy:23791,etcd2:2379,etcd3:2379"

and create the proxy after startup:

    curl -s -X POST localhost:8474/proxies -d '{
      "name": "etcd1", "listen": "0.0.0.0:23791", "upstream": "etcd1:2379"
    }'

## Fault recipes

    # 2.5s latency on patroni2 -> etcd1 (probe the failsafe 2s timeout edge)
    curl -s -X POST localhost:8474/proxies/etcd1/toxics -d '{
      "name": "latency_downstream", "type": "latency", "attributes": {"latency": 2500}}'

    # hard cut of just this path (asymmetric partition)
    curl -s -X POST localhost:8474/proxies/etcd1/toxics -d '{
      "type": "timeout", "attributes": {"timeout": 0}}'

    # remove all toxics
    curl -s -X DELETE localhost:8474/proxies/etcd1/toxics/latency_downstream

## What to demonstrate

1. One member losing its etcd path while the leader keeps its own — the
   member falls back to the remaining hosts in `PATRONI_ETCD3_HOSTS`; then
   proxy *all* of a node's DCS paths to show real isolation.
2. The failsafe 2-second timeout edge described in the chaos README —
   latency > 2 s between leader and a member during DCS quorum loss keeps
   failsafe from engaging even though everything is "up".
