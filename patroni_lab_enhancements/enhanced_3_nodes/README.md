# Enhanced 3-node Patroni lab

The flagship environment of the enhancement package: three Patroni/PostgreSQL
nodes, a **genuine 3-node etcd quorum**, HAProxy, a full Prometheus/Grafana
observability stack, a continuous write client, and an RPO/RTO measurement
harness. Replication behaviour (async / quorum / strict) and HA timers are
switched at runtime through the DCS, so one running cluster serves the whole
experiment matrix.

## Quick start

    make up          # build, start, wait for convergence
    make status      # patronictl list

Service access:
* **Grafana**: http://localhost:3000 (dashboard 'Patroni Lab Overview')
* **Prometheus**: http://localhost:9090
* **HAProxy**: http://localhost:7000

## Learning path

1. `docs/01_architecture.md` — components and the design decisions behind them
2. `docs/02_replication_profiles.md` — async vs quorum vs strict, timer tuning
3. `docs/03_scenarios.md` — all failure scenarios with expected timelines
4. `docs/04_observability.md` — metrics, dashboard, demo choreography
5. `docs/05_watchdog.md` — softdog self-fencing (optional, Linux host)
6. `docs/06_rpo_rto.md` — measuring instead of claiming

## Scenario index

| Command | Demonstrates |
|---|---|
| `make scenario-failover` | hard leader crash, automatic failover, pg_rewind rejoin |
| `make scenario-switchover` | planned zero-loss switchover |
| `make scenario-dcs-degraded` | 1/3 etcd down: nothing happens (the point) |
| `make scenario-dcs-quorum-loss` | 2/3 etcd down: primary demotes to read-only |
| `make scenario-failsafe-demo` | same outage with failsafe_mode off vs on |
| `make scenario-partition-leader` | split-brain drill: isolated leader self-demotes |
| `make scenario-reinit-replica` | broken replica, `patronictl reinit` |
| `make pause` / `make resume` | maintenance mode |
| `make measure-rpo-rto` | quantitative RPO/RTO under any of the above |

## Version pinning

All image tags and the Patroni/PostgreSQL versions are pinned in `.env`.
Change `PG_MAJOR` (14–18 supported by Patroni 4.x) and `make clean up` to
test another major version.
