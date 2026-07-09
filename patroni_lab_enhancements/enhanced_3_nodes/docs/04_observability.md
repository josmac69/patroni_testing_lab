# Observability

## What is scraped

| Target | Endpoint | Key series |
|---|---|---|
| Patroni | `:8008/metrics` (since 2.1.0) | `patroni_primary`, `patroni_replica`, `patroni_postgres_running`, `patroni_postgres_timeline`, `patroni_xlog_location`, `patroni_xlog_replayed_location`, `patroni_pending_restart`, `patroni_dcs_last_seen` |
| postgres_exporter | `:9187/metrics` | `pg_stat_database_xact_commit`, replication views |
| etcd | `:2379/metrics` | `etcd_server_has_leader`, `etcd_server_leader_changes_seen_total` |
| HAProxy | `:8404/metrics` | `haproxy_server_status`, check transitions |

Note on naming: older Patroni versions exposed `patroni_master`; current
versions expose `patroni_primary` (with the old name kept for
compatibility). If a panel is empty, check which name your pinned version
emits.

## The demo choreography that works in talks

1. Open Grafana next to the terminal before triggering anything.
2. Trigger `make scenario-failover`.
3. Narrate from the panels: commit rate collapses → `patroni_primary` flips
   → timeline increments → commit rate recovers. The RTO is *visible* as the
   width of the gap; no log-reading needed.
4. `patroni_dcs_last_seen` is the one to watch during the DCS scenarios —
   it stops advancing the moment quorum is lost, before anything else
   reacts.

## Useful ad-hoc queries

    # is there exactly one primary? (alerting condition: != 1)
    sum(patroni_primary)

    # seconds since each Patroni last saw the DCS
    time() - patroni_dcs_last_seen

    # pending_restart flags after config changes
    patroni_pending_restart

## Beyond the provisioned dashboard

The provisioned dashboard is intentionally minimal and readable during a
live demo. For a fuller production-style view import Grafana.com dashboard
ID 18870 (Patroni, built against the /metrics endpoint) and etcd's official
dashboard, and compare what they add.
