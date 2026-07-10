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

## Actionable Sequence

### Step 1: Record baseline metrics
Run the RPO/RTO metrics baseline on the old PostgreSQL version:
```bash
cd ../enhanced_3_nodes
make measure-rpo-rto
```

### Step 2: Build the new PostgreSQL version images
Modify `.env` in `enhanced_3_nodes` (e.g. update `PG_MAJOR` from `17` to `18`), then rebuild:
```bash
docker compose build
```
*(Ensure the Dockerfile contains packages for both versions so `pg_upgrade` has access to both sets of binaries).*

### Step 3: Run the automated upgrade script
Run the scripted upgrade procedure for the leader node from the `upgrade_pg_major/` folder:
```bash
cd ../upgrade_pg_major
OLD=17 NEW=18 LEADER=patroni1 ./upgrade_leader.sh
```

### Step 4: Rebuild/Reinitialize the standby replicas
Standby nodes cannot be linked-upgraded; they must be re-initialized against the new leader:
```bash
# Reinit standby patroni2:
docker compose -f ../enhanced_3_nodes/docker-compose.yml exec patroni1 patronictl -c /tmp/patroni.yml reinit lab patroni2 --force

# Reinit standby patroni3:
docker compose -f ../enhanced_3_nodes/docker-compose.yml exec patroni1 patronictl -c /tmp/patroni.yml reinit lab patroni3 --force
```

### Step 5: Resume Patroni and optimize catalog
Resume normal cluster monitoring and optimize the system catalogs (since stat tables are not copied):
```bash
# Resume cluster management:
docker compose -f ../enhanced_3_nodes/docker-compose.yml exec patroni1 patronictl -c /tmp/patroni.yml resume

# Run analyze/vacuum across databases:
docker compose -f ../enhanced_3_nodes/docker-compose.yml exec patroni1 vacuumdb -h localhost -p 5432 -U postgres --all --analyze-in-stages
```

### Step 6: Verify upgraded RPO/RTO metrics
```bash
make -C ../enhanced_3_nodes measure-rpo-rto
```

## Discussion points for training

* Downtime window = steps 4–7; measure it. Compare against logical
  replication upgrade strategies (near-zero downtime, much more machinery).
* `--link` makes rollback impossible the moment the new cluster starts;
  the pgBackRest full backup taken immediately before is the actual
  rollback plan.
* Extensions: `pg_upgrade --check` does not validate extension binary
  compatibility for the new major; verify each extension explicitly.
