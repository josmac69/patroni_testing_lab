# Failure scenarios — guide with expected timelines

Every scenario below states purpose, command, expected observable timeline,
and what to show in Grafana. Run `make measure-rpo-rto` in a second terminal
whenever quantitative results are wanted.

---

## 01 Leader crash (`make scenario-failover`)

**Purpose.** The canonical unplanned failover: SIGKILL, no checkpoint.

**Expected timeline (default timers, async profile).**

| t | event |
|---|---|
| 0 s | leader killed; client INSERTs start failing |
| ≤ 30 s | leader key expires in etcd (`ttl`) |
| +0–10 s | replicas race; healthiest one (within `maximum_lag_on_failover`) takes the key and promotes |
| +3–9 s | HAProxy `/primary` check flips (`inter 3s fall 3 rise 2`); writes resume |

Grafana: `patroni_primary` moves from one instance to another;
`patroni_postgres_timeline` increments; commit-rate panel shows the gap.

**Aftermath.** Restarting the old leader shows the `pg_rewind` path —
its timeline diverged, Patroni rewinds it and it rejoins as a replica.

## 02 Planned switchover (`make scenario-switchover`)

**Purpose.** Contrast with 01: checkpoint, orderly demote, promote. Expected
RPO 0 in every profile; RTO a few seconds. This is what maintenance windows
should look like; the difference to scenario 01 is the entire argument for
scheduled switchovers before host maintenance.

## 03 DCS degradation vs quorum loss (`make scenario-dcs-degraded` / `-quorum-loss` / `-recover`)

**Purpose.** Separate two situations often conflated:

* one etcd member down → nothing happens (quorum 2/3 holds);
* two down → quorum lost → primary demotes to read-only within `ttl`.

While quorum is lost: writes via :5000 fail, reads via :5001 keep working —
the data plane outlives the control plane, but only read-only.

## 04 Failsafe mode (`make scenario-failsafe-demo`)

**Purpose.** The Patroni ≥ 3.0 answer to "why should an etcd outage take
down my primary?". The script runs the quorum-loss experiment twice —
failsafe off, then on — and prints the differing outcomes. With failsafe on,
the leader keeps its role as long as it can reach **all** cluster members
via `POST /failsafe`.

**Caveats to teach.** The member check has a hardcoded 2 s timeout; on
high-latency links the failsafe may not engage. Failsafe also cannot help
when the leader is partitioned from members *and* DCS simultaneously.

## 05 Leader network partition (`make scenario-partition-leader` / `-heal`)

**Purpose.** The split-brain drill. The partitioned leader is alive but
isolated: it must demote itself (cannot refresh the key) while the majority
elects a new leader. Healing shows pg_rewind reconciling the diverged
timeline.

**What to verify during the partition.** Connect to the isolated node
directly (`docker compose exec patroniX psql ...`) and confirm it answers
`SELECT pg_is_in_recovery()` with `t` or refuses writes — this is the
guarantee that no second writable primary exists. Compare with the chaos
lab for *partial* partitions, where the guarantees get more interesting.

## 06 Replica rebuild (`make scenario-reinit-replica`)

**Purpose.** Operator routine: a replica with a destroyed pg_control cannot
start; `patronictl reinit` wipes and re-clones it. Discuss the load impact
of `pg_basebackup` on the primary and how `create_replica_methods` with
pgBackRest (see `../backup_pgbackrest/`) removes that load.

## 07 Maintenance pause (`make pause` / `make resume`)

**Purpose.** In pause mode Patroni stops managing PostgreSQL: no failover,
no configuration enforcement. Required for `pg_upgrade` (see
`../upgrade_pg_major/`) and any manual surgery. Show that killing PostgreSQL
during pause does **not** trigger a failover — and discuss why that is both
the point and the risk.
