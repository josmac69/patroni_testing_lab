# Major-version upgrade under Patroni (pg_upgrade runbook)

Upgrades a running lab cluster from `PG_MAJOR=N` to `N+1` (e.g. 17 → 18)
with `pg_upgrade --link`. Patroni does not automate major upgrades; the
value of this lab is a rehearsed, scripted sequence of the manual steps —
including the two that are most often gotten wrong (DCS wipe, standby
rebuild).

## Why the DCS must be wiped

`pg_upgrade` runs `initdb` for the new cluster, which generates a **new
system identifier**. The Patroni cluster state in etcd still records the old
one; on startup Patroni would refuse to manage the "foreign" cluster.
`patronictl remove <scope>` deletes the cluster's DCS state so the upgraded
node can re-bootstrap the scope.

## Why standbys are rebuilt, not upgraded

Running `pg_upgrade` on a standby is unsupported. The options are the rsync
hard-link procedure from the PostgreSQL docs (fast, delicate) or a plain
rebuild via `patronictl reinit` / `create_replica_methods` (slow, safe). The
lab uses rebuild; for the 6 TB-class real-world case, rehearse the rsync
procedure separately and pair it with the pgBackRest lab so the rebuild does
not read from the primary.

## Sequence (see `upgrade_leader.sh` for the executable version)

 1. `make measure-rpo-rto` baseline on the old version; note results.
 2. Build new images: set `PG_MAJOR` in `.env`, `docker compose build`.
    Images must contain **both** binaries (old + new) for `pg_upgrade`;
    the script documents the Dockerfile adjustment
    (`apt-get install postgresql-<old>` alongside the base image's new
    version, both from PGDG).
 3. `patronictl pause` — Patroni stops managing PostgreSQL.
 4. Stop PostgreSQL cleanly on all nodes (leader last).
 5. On the leader: `initdb` the new data dir, `pg_upgrade --link --check`,
    then the real run.
 6. `patronictl remove <scope>` — wipe DCS state (the step people forget).
 7. Start Patroni on the leader with the new data dir → it re-bootstraps
    the scope as a new cluster on the upgraded PostgreSQL.
 8. Reinit both standbys.
 9. `patronictl resume` (if paused state persisted), run
    `vacuumdb --all --analyze-in-stages`, re-run the RPO/RTO baseline.

## Discussion points for training

* Downtime window = steps 4–7; measure it. Compare against logical
  replication upgrade strategies (near-zero downtime, much more machinery).
* `--link` makes rollback impossible the moment the new cluster starts;
  the pgBackRest full backup taken immediately before is the actual
  rollback plan.
* Extensions: `pg_upgrade --check` does not validate extension binary
  compatibility for the new major; verify each extension explicitly.
