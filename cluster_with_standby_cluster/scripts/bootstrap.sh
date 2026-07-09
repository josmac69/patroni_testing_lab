#!/usr/bin/env bash
# scripts/bootstrap.sh: Implements a realistic bootstrap sequence for a primary and standby cluster.
# It starts the DCS and primary node first, creates the schema and inserts
# some initial records, then spins up the replica nodes which clone the database,
# and finally starts HAProxy and the standby cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_DIR}"

echo "=== STEP 1: Cleaning previous environment ==="
docker compose down -v

echo "=== STEP 2: Starting Primary DCS (berlin-etcd) and Primary Node (berlin-patroni1) ==="
docker compose up -d berlin-etcd berlin-patroni1

echo "=== STEP 3: Waiting for berlin-patroni1 to bootstrap as Leader ==="
until docker compose exec berlin-patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'berlin-patroni1.*Leader.*running'; do
    echo -n "."
    sleep 2
done
echo ""
echo "berlin-patroni1 is ready and acting as the Primary Cluster Leader."

echo "=== STEP 3b: Creating physical replication slot 'standby_slot' on berlin-patroni1 ==="
docker compose exec berlin-patroni1 bash -c "PGPASSWORD=postgres_password psql -h localhost -U postgres -d postgres -c \"SELECT pg_create_physical_replication_slot('standby_slot');\"" || true

echo "=== STEP 4: Creating data model and digesting initial records (MAX_RECORDS=10) ==="
# We run the ingestion client inside berlin-patroni1 pointing to its localhost postgres instance
docker compose exec -e DB_HOST=localhost -e DB_PORT=5432 -e MAX_RECORDS=10 berlin-patroni1 python3 /scripts/ingest.py

echo "=== STEP 5: Verifying records exist on primary (berlin-patroni1) ==="
docker compose exec berlin-patroni1 bash -c "PGPASSWORD=postgres_password psql -h localhost -U postgres -d postgres -c 'SELECT id, sensor_name, reading_value, recorded_at FROM sensor_readings ORDER BY id ASC;'"

echo "=== STEP 6: Starting primary replicas (berlin-patroni2 & berlin-patroni3) ==="
docker compose up -d berlin-patroni2 berlin-patroni3

echo "=== STEP 7: Waiting for primary replicas to clone and join streaming replication ==="
until docker compose exec berlin-patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'berlin-patroni2.*Replica.*streaming' && \
      docker compose exec berlin-patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'berlin-patroni3.*Replica.*streaming'; do
    echo -n "."
    sleep 2
done
echo ""
docker compose exec berlin-patroni1 patronictl -c /etc/patroni/patroni.yml list

echo "=== STEP 8: Starting Primary HAProxy ==="
docker compose up -d berlin-haproxy
sleep 3

echo "=== STEP 9: Starting Standby DCS (bonn-etcd) and Standby Leader Node (bonn-patroni1) ==="
docker compose up -d bonn-etcd bonn-patroni1

echo "=== STEP 10: Waiting for bonn-patroni1 to bootstrap as Standby Leader ==="
until docker compose exec bonn-patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -iE 'bonn-patroni1.*Standby Leader.*(running|streaming)'; do
    echo -n "."
    sleep 2
done
echo ""
echo "bonn-patroni1 is ready and acting as the Standby Cluster Leader."

echo "=== STEP 11: Starting standby replicas (bonn-patroni2 & bonn-patroni3) ==="
docker compose up -d bonn-patroni2 bonn-patroni3

echo "=== STEP 12: Waiting for standby replicas to clone and join streaming replication ==="
until docker compose exec bonn-patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'bonn-patroni2.*Replica.*streaming' && \
      docker compose exec bonn-patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'bonn-patroni3.*Replica.*streaming'; do
    echo -n "."
    sleep 2
done
echo ""
docker compose exec bonn-patroni1 patronictl -c /etc/patroni/patroni.yml list

echo "=== STEP 13: Verifying replication from Primary directly on Standby Leader ==="
docker compose exec bonn-patroni1 bash -c "PGPASSWORD=postgres_password psql -h localhost -U postgres -d postgres -c 'SELECT count(*) as total_rows, max(id) as max_id FROM sensor_readings;'"

echo "=== STEP 14: Starting Standby HAProxy and Continuous Ingestion Client ==="
docker compose up -d bonn-haproxy berlin-client

echo "=== STEP 15: Final Clusters Status ==="
echo "--- PRIMARY CLUSTER ---"
docker compose exec berlin-patroni1 patronictl -c /etc/patroni/patroni.yml list
echo "--- STANDBY CLUSTER ---"
docker compose exec bonn-patroni1 patronictl -c /etc/patroni/patroni.yml list

echo "Bootstrap sequence completed successfully! Replicas cloned the databases, caught up, and are streaming."
