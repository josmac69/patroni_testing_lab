# pgBackRest integration lab

Extends the enhanced 3-node lab with a pgBackRest repository so the cluster
gains what Patroni alone does not provide: real backups, point-in-time
recovery, and replica creation **from the repository instead of from the
primary**.

## What Patroni does and does not do

Patroni is an HA orchestrator, not a backup tool. Replication protects
against node loss, not against `DROP TABLE` — a bad statement replicates in
milliseconds. This lab exists to make that distinction physical.

## Architecture (Pre-Configured Out-of-the-Box)

The flagship `enhanced_3_nodes` stack comes pre-configured with pgBackRest:
* A shared named volume `backrest_repo` is already declared and mounted at `/var/lib/pgbackrest` on all three Patroni nodes.
* `pgbackrest` is pre-installed in the Patroni Docker image.
* `/etc/pgbackrest.conf` is pre-configured and mounted into the containers from the host.
* `archive_command`/`archive_mode` are managed **through Patroni** — never in `postgresql.conf` directly. To enable archiving, run:

      make -C ../enhanced_3_nodes profile-async   # any profile
      docker compose exec patroni1 patronictl -c /tmp/patroni.yml edit-config --force \
        -s "postgresql.parameters.archive_mode=on" \
        -s "postgresql.parameters.archive_command=pgbackrest --stanza=lab archive-push %p"

## The three integration points (see `patroni-pgbackrest-snippet.yml`)

1. **`create_replica_methods: [pgbackrest, basebackup]`** — `patronictl
   reinit` and new-replica bootstrap restore from the repo first
   (`--delta`), falling back to `pg_basebackup`. Teaching point: rebuilding
   a 6 TB replica from the primary saturates the primary's I/O; from the
   repo, the primary does not notice.
2. **`bootstrap.method: pgbackrest_restore`** — bootstrap an entire new
   cluster from a backup, the disaster-recovery cold start.
3. **PITR** — restore to a timestamp before the bad statement
   (`docs/pitr_runbook.md`).

## Order of operations (first run)

    # 1. enable archiving via patronictl (above), restart if pending
    # 2. create the stanza and take the first full backup (on the LEADER):
    docker compose exec patroni1 pgbackrest --stanza=lab stanza-create
    docker compose exec patroni1 pgbackrest --stanza=lab --type=full backup
    docker compose exec patroni1 pgbackrest --stanza=lab info

    # 3. prove the replica-from-repo path:
    make -C ../enhanced_3_nodes scenario-reinit-replica
    # then check the victim's logs for 'restore' from pgbackrest, not basebackup
