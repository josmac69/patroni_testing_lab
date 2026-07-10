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

Add the service from `pgbouncer/compose-snippet.yml` to the enhanced lab and point the ingestion client at `pgbouncer:6432`.

### How to test:
1. Append the `pgbouncer` service snippet from `pgbouncer/compose-snippet.yml` under the `services:` block in `enhanced_3_nodes/docker-compose.yml`.
2. Spin up the pooler:
   ```bash
   cd ../enhanced_3_nodes
   docker compose up -d pgbouncer
   ```
3. Run the harness client to connect through PgBouncer:
   ```bash
   docker compose exec client python rpo_rto_harness.py --duration 120
   ```
4. Re-run `make measure-rpo-rto` and compare RTO with the baseline. Transaction pooling typically *smooths* the post-failover reconnect storm.

Failover-relevant settings in `pgbouncer.ini`:
`server_login_retry` (how fast the pooler retries the backend after failure) and `query_wait_timeout` (how long client queries queue during the outage before erroring).

## 2. libpq multi-host (no extra service)

Run the test client container using a multi-host connection string directly targeting the Patroni node hosts:
```bash
docker compose exec client psql "host=patroni1,patroni2,patroni3 port=5432,5432,5432 target_session_attrs=read-write user=postgres dbname=postgres" -c "SELECT pg_is_in_recovery();"
```

To demo client-side failover without HAProxy:
1. Publish each node's `5432` port to unique host ports in `docker-compose.yml`.
2. Connect from the host machine using:
   ```bash
   psql "host=localhost,localhost,localhost port=5432,5433,5434 target_session_attrs=read-write user=postgres"
   ```

## 3. vip-manager (documented, not containerized)

vip-manager watches the Patroni leader key in the DCS and moves a virtual IP
to whichever host holds it. It removes the proxy hop entirely, but needs an
L2 segment where the VIP can float (or cloud-provider API integration) —
inherently host-level, so it is documented here rather than shipped as a
container. Sketch for a host-network demo on Linux:

    vip-manager --ip 192.168.56.100 --netmask 24 --interface eth1 \
      --trigger-key /service/lab/leader --trigger-value patroni1 \
      --dcs-type etcd3 --dcs-endpoints http://127.0.0.1:2379
