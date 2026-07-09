#!/bin/bash
# Executable skeleton of the leader upgrade (steps 3-7 of the runbook).
# Deliberately verbose and stop-on-error; intended to be read as much as run.
#
# Prerequisites:
#   * images rebuilt so both $OLD and $NEW binaries exist under
#     /usr/lib/postgresql/{$OLD,$NEW}/bin  (PGDG packages)
#   * a fresh pgBackRest full backup (your rollback plan)
set -euo pipefail
cd "$(dirname "$0")/../enhanced_3_nodes"

OLD=${OLD:?set OLD, e.g. OLD=17}
NEW=${NEW:?set NEW, e.g. NEW=18}
SCOPE=${SCOPE:-lab}
LEADER=${LEADER:?set LEADER, e.g. LEADER=patroni1}
DATA_OLD=/var/lib/postgresql/data/pgdata
DATA_NEW=/var/lib/postgresql/data/pgdata_${NEW}

run() { docker compose exec -T "$LEADER" bash -c "$*"; }

echo "== pausing Patroni =="
run "patronictl -c /tmp/patroni.yml pause"

echo "== stopping PostgreSQL on standbys, then leader =="
for n in patroni1 patroni2 patroni3; do
    [[ "$n" == "$LEADER" ]] && continue
    docker compose exec -T "$n" bash -c \
      "pg_ctl stop -D $DATA_OLD -m fast" || true
done
run "pg_ctl stop -D $DATA_OLD -m fast"

echo "== initdb for $NEW =="
run "/usr/lib/postgresql/$NEW/bin/initdb -k -E UTF8 -D $DATA_NEW"

echo "== pg_upgrade --check =="
run "cd /tmp && /usr/lib/postgresql/$NEW/bin/pg_upgrade \
      -b /usr/lib/postgresql/$OLD/bin -B /usr/lib/postgresql/$NEW/bin \
      -d $DATA_OLD -D $DATA_NEW --link --check"

echo "== pg_upgrade (real run) =="
run "cd /tmp && /usr/lib/postgresql/$NEW/bin/pg_upgrade \
      -b /usr/lib/postgresql/$OLD/bin -B /usr/lib/postgresql/$NEW/bin \
      -d $DATA_OLD -D $DATA_NEW --link"

echo "== swapping data directories =="
run "mv $DATA_OLD ${DATA_OLD}_${OLD}_retired && mv $DATA_NEW $DATA_OLD"

echo "== wiping DCS state for scope '$SCOPE' (new system identifier) =="
run "echo $SCOPE | patronictl -c /tmp/patroni.yml remove $SCOPE"

echo "== restart Patroni container; it re-bootstraps the scope on PG $NEW =="
docker compose restart "$LEADER"

cat <<'NEXT'
Next steps (manual):
  patronictl reinit for both standbys
  vacuumdb --all --analyze-in-stages
  re-run make measure-rpo-rto and compare with the pre-upgrade baseline
NEXT
