#!/usr/bin/env bash
# scripts/bootstrap.sh: Implements a realistic bootstrap sequence.
# It starts the DCS and primary node first, creates the schema and inserts
# some initial records, then spins up the replica nodes which clone the database,
# and finally starts HAProxy and the continuous ingestion client.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_DIR}"

echo "=== STEP 1: Cleaning previous environment ==="
docker compose down -v

echo "=== STEP 2: Starting DCS (etcd) and Primary (patroni1) ==="
docker compose up -d etcd patroni1

echo "=== STEP 3: Waiting for patroni1 to bootstrap as Leader ==="
until docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'patroni1.*Leader.*running'; do
    echo -n "."
    sleep 2
done
echo ""
echo "patroni1 is ready and acting as the cluster Leader."

echo "=== STEP 4: Creating data model and digesting initial records (MAX_RECORDS=10) ==="
# We run the ingestion client inside patroni1 pointing to its localhost postgres instance
docker compose exec -e DB_HOST=localhost -e DB_PORT=5432 -e MAX_RECORDS=10 patroni1 python3 /scripts/ingest.py

echo "=== STEP 5: Verifying records exist on primary (patroni1) ==="
docker compose exec patroni1 bash -c "PGPASSWORD=postgres_password psql -h localhost -U postgres -d postgres -c 'SELECT id, sensor_name, reading_value, recorded_at FROM sensor_readings ORDER BY id ASC;'"

echo "=== STEP 6: Starting replicas (patroni2 & patroni3) to clone primary data ==="
docker compose up -d patroni2 patroni3

echo "=== STEP 7: Waiting for replicas to clone and join streaming replication ==="
until docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'patroni2.*Replica.*streaming' && \
      docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'patroni3.*Replica.*streaming'; do
    echo -n "."
    sleep 2
done
echo ""
docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml list

echo "=== STEP 8: Verifying replication directly on standby replicas ==="
echo "Checking patroni2 (Standby Replica):"
docker compose exec patroni2 bash -c "PGPASSWORD=postgres_password psql -h localhost -U postgres -d postgres -c 'SELECT count(*) as total_rows, max(id) as max_id FROM sensor_readings;'"

echo "Checking patroni3 (Standby Replica):"
docker compose exec patroni3 bash -c "PGPASSWORD=postgres_password psql -h localhost -U postgres -d postgres -c 'SELECT count(*) as total_rows, max(id) as max_id FROM sensor_readings;'"

echo "=== STEP 9: Starting HAProxy and Continuous Ingestion Client ==="
docker compose up -d haproxy client

echo "=== STEP 10: Final Cluster Status ==="
docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml list
echo "Bootstrap sequence completed successfully! Replicas cloned the primary database, caught up, and are streaming."
