# Point-in-time recovery runbook (lab)

Scenario: at T someone runs `DROP TABLE sensor_data`. Streaming replication
has already replicated the drop everywhere. Recovery target: T minus 1 s.

## Steps

1. **Stop Patroni from fighting you.** PITR rewinds the timeline; Patroni
   would try to "heal" the cluster back. Take the whole cluster down:

       docker compose stop patroni2 patroni3
       docker compose exec patroni1 patronictl -c /tmp/patroni.yml pause
       docker compose exec patroni1 bash -c 'pg_ctl stop -D /var/lib/postgresql/data/pgdata -m fast'

2. **Restore on one node with a recovery target:**

       docker compose exec patroni1 pgbackrest --stanza=lab --delta \
         --type=time "--target=2026-07-09 14:31:59+02" \
         --target-action=promote restore

3. **Start PostgreSQL manually, verify the table is back, let it promote
   onto a new timeline.**

4. **Reset cluster state in the DCS.** The DCS still describes the old
   timeline history; wipe it and re-bootstrap Patroni around the restored
   node:

       docker compose exec patroni1 patronictl -c /tmp/patroni.yml remove lab
       docker compose restart patroni1

5. **Reinit the other members** (they are now on a dead timeline):

       docker compose start patroni2 patroni3
       docker compose exec patroni1 patronictl -c /tmp/patroni.yml reinit lab patroni2 --force
       docker compose exec patroni1 patronictl -c /tmp/patroni.yml reinit lab patroni3 --force

## Teaching points

* PITR under Patroni is a *cluster-wide* operation; restoring a single node
  while Patroni runs produces a member on a divergent timeline that Patroni
  will immediately try to reinitialize.
* `--target-action=promote` vs `pause`: pause first when the exact target
  time is uncertain, inspect, then promote.
* Discuss RPO here too: archive_command lag bounds PITR freshness; the
  `archive-push` asynchronous queue settings trade safety for throughput.
