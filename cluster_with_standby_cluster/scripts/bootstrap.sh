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

echo "=== STEP 2: Starting Primary DCS (primary-etcd) and Primary Node (primary-patroni1) ==="
docker compose up -d primary-etcd primary-patroni1

echo "=== STEP 3: Waiting for primary-patroni1 to bootstrap as Leader ==="
until docker compose exec primary-patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'primary-patroni1.*Leader.*running'; do
    echo -n "."
    sleep 2
done
echo ""
echo "primary-patroni1 is ready and acting as the Primary Cluster Leader."

echo "=== STEP 3b: Creating physical replication slot 'standby_slot' on primary-patroni1 ==="
docker compose exec primary-patroni1 bash -c "PGPASSWORD=postgres_password psql -h localhost -U postgres -d postgres -c \"SELECT pg_create_physical_replication_slot('standby_slot');\""

echo "=== STEP 4: Creating data model and digesting initial records (MAX_RECORDS=10) ==="
# We run the ingestion client inside primary-patroni1 pointing to its localhost postgres instance
docker compose exec -e DB_HOST=localhost -e DB_PORT=5432 -e MAX_RECORDS=10 primary-patroni1 python3 /scripts/ingest.py

echo "=== STEP 5: Verifying records exist on primary (primary-patroni1) ==="
docker compose exec primary-patroni1 bash -c "PGPASSWORD=postgres_password psql -h localhost -U postgres -d postgres -c 'SELECT id, sensor_name, reading_value, recorded_at FROM sensor_readings ORDER BY id ASC;'"

echo "=== STEP 6: Starting primary replicas (primary-patroni2 & primary-patroni3) ==="
docker compose up -d primary-patroni2 primary-patroni3

echo "=== STEP 7: Waiting for primary replicas to clone and join streaming replication ==="
until docker compose exec primary-patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'primary-patroni2.*Replica.*streaming' && \
      docker compose exec primary-patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'primary-patroni3.*Replica.*streaming'; do
    echo -n "."
    sleep 2
done
echo ""
docker compose exec primary-patroni1 patronictl -c /etc/patroni/patroni.yml list

echo "=== STEP 8: Starting Primary HAProxy ==="
docker compose up -d primary-haproxy
sleep 3

echo "=== STEP 9: Starting Standby DCS (standby-etcd) and Standby Leader Node (standby-patroni1) ==="
docker compose up -d standby-etcd standby-patroni1

echo "=== STEP 10: Waiting for standby-patroni1 to bootstrap as Standby Leader ==="
until docker compose exec standby-patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -iE 'standby.*leader.*running'; do
    echo -n "."
    sleep 2
done
echo ""
echo "standby-patroni1 is ready and acting as the Standby Cluster Leader."

echo "=== STEP 11: Starting standby replicas (standby-patroni2 & standby-patroni3) ==="
docker compose up -d standby-patroni2 standby-patroni3

echo "=== STEP 12: Waiting for standby replicas to clone and join streaming replication ==="
until docker compose exec standby-patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'standby-patroni2.*Replica.*streaming' && \
      docker compose exec standby-patroni1 patronictl -c /etc/patroni/patroni.yml list 2>/dev/null | grep -q 'standby-patroni3.*Replica.*streaming'; do
    echo -n "."
    sleep 2
done
echo ""
docker compose exec standby-patroni1 patronictl -c /etc/patroni/patroni.yml list

echo "=== STEP 13: Verifying replication from Primary directly on Standby Leader ==="
docker compose exec standby-patroni1 bash -c "PGPASSWORD=postgres_password psql -h localhost -U postgres -d postgres -c 'SELECT count(*) as total_rows, max(id) as max_id FROM sensor_readings;'"

echo "=== STEP 14: Starting Standby HAProxy and Continuous Ingestion Client ==="
docker compose up -d standby-haproxy primary-client

echo "=== STEP 15: Final Clusters Status ==="
echo "--- PRIMARY CLUSTER ---"
docker compose exec primary-patroni1 patronictl -c /etc/patroni/patroni.yml list
echo "--- STANDBY CLUSTER ---"
docker compose exec standby-patroni1 patronictl -c /etc/patroni/patroni.yml list

echo "Bootstrap sequence completed successfully! Replicas cloned the databases, caught up, and are streaming."
