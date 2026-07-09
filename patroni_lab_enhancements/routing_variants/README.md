# Connection routing variants

The enhanced lab routes through HAProxy. That is one of four common
patterns; each moves the failover-detection latency and the
single-point-of-failure question to a different place. This module provides
a PgBouncer variant to run, and comparison notes for the other two.

## The comparison that matters (fill with measured values)

| Pattern | RTO contribution | SPOF | Read/write split | Notes |
|---|---|---|---|---|
| HAProxy (baseline) | check `inter × fall` (≈9 s default) | HAProxy itself | yes (:5000/:5001) | role decided by Patroni REST |
| PgBouncer behind HAProxy | + pooler reconnect | pooler + LB | yes | pooling absorbs reconnect storms after failover |
| libpq multi-host | client retry loop only | none | `target_session_attrs` | zero infra; every client must be configured |
| vip-manager | VIP move on DCS key change | none (VIP follows leader) | write VIP only | L2 networks; closest to "classic" HA feel |

## 1. PgBouncer (`pgbouncer/`)

Add the service from `pgbouncer/compose-snippet.yml` to the enhanced lab and
point the ingestion client at `pgbouncer:6432`. Re-run
`make measure-rpo-rto` and compare RTO with the baseline: transaction
pooling typically *smooths* the post-failover reconnect storm (existing
server connections die once, clients queue instead of erroring), at the cost
of session features (prepared statements need `max_prepared_statements`,
PgBouncer ≥ 1.21).

Failover-relevant settings in `pgbouncer.ini`:
`server_login_retry` (how fast the pooler retries the backend after failure)
and `query_wait_timeout` (how long client queries queue during the outage
before erroring — effectively the pooler's opinion about your RTO budget).

## 2. libpq multi-host (no extra service)

    psql "host=localhost,localhost,localhost port=5432,5433,5434 \
          target_session_attrs=read-write user=postgres"

To demo without HAProxy, publish each node's 5432 on distinct host ports.
Teaching points: `target_session_attrs=read-write` (≥ PG 10) vs `primary` /
`prefer-standby` (≥ PG 14); detection happens at *connect* time only — a
long-lived connection to a demoted primary is not magically redirected,
which is exactly what HAProxy's `on-marked-down shutdown-sessions` solves
at the LB layer. Combine with `connect_timeout` and connection retry in the
application for the full client-side HA story.

## 3. vip-manager (documented, not containerized)

vip-manager watches the Patroni leader key in the DCS and moves a virtual IP
to whichever host holds it. It removes the proxy hop entirely, but needs an
L2 segment where the VIP can float (or cloud-provider API integration) —
inherently host-level, so it is documented here rather than shipped as a
container. Sketch for a host-network demo on Linux:

    vip-manager --ip 192.168.56.100 --netmask 24 --interface eth1 \
      --trigger-key /service/lab/leader --trigger-value patroni1 \
      --dcs-type etcd3 --dcs-endpoints http://127.0.0.1:2379
