# Patroni PostgreSQL HA testing lab

This repository contains a local testing lab for setting up a highly available PostgreSQL cluster managed by **Patroni** and **etcd**, with **HAProxy** acting as the load balancer.

## Architecture

*   **`etcd`**: Distributed Consensus Store (DCS) for cluster state coordination.
*   **`patroni1`, `patroni2`, `patroni3`**: Three PostgreSQL 16 nodes managed by Patroni.
*   **`haproxy`**: Access proxy routing connections to the primary node on port `5000` (read-write) and standby nodes on port `5001` (read-only).

---

## Detailed Documentation

To learn more about the configuration, topology, and management of the cluster, check out the following guides:

*   **[Architecture Guide](docs/architecture.md)**: Visual and textual walkthrough of the high availability topology, network ports, failover dynamics, and split-brain prevention.
*   **[Patroni Configuration & Operations Guide](docs/patroni.md)**: Comprehensive details on `patroni.yml` settings, REST API endpoints, and a cheatsheet for the `patronictl` administrative tool.
*   **[HAProxy Load Balancing & Routing Guide](docs/haproxy.md)**: Breakdown of `haproxy.cfg`, dynamic health-checking mechanisms, active session termination (`on-marked-down`), and failover latency.

---

## Makefile Helper Commands

A `Makefile` is provided to simplify managing, testing, and inspecting the cluster. Run `make help` or use any of the following:

*   **`make up`**: Build the custom images and start the cluster in the background.
*   **`make down`**: Stop the running cluster containers.
*   **`make clean`**: Stop the cluster and destroy the named PostgreSQL volumes (resets all data!).
*   **`make status`**: Show the active Patroni cluster membership, role, lag, and timeline details.
*   **`make ps`**: Show the docker container statuses.
*   **`make logs`**: Stream the logs of all containers.
*   **`make failover`**: Run the manual Patroni failover wizard.
*   **`make write-test`**: Run a test INSERT statement via the HAProxy write-only port `5000`.
*   **`make read-test`**: Run a test SELECT statement via the HAProxy read-only port `5001`.

---

## Getting Started

### 1. Build and Start the Cluster

To build the custom Postgres+Patroni image and start all containers:
```bash
docker compose up --build -d
```

Verify that all containers are running:
```bash
docker compose ps
```

### 2. Monitor Cluster Initialization

You can check the Patroni cluster status by running `patronictl list` inside any of the Patroni containers:
```bash
docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml list
```

Example output:
```text
+ Cluster: patroni-cluster (7388371992738918237) ---+----+-----------+
| Member   | Host     | Role    | State   | TL | Lag in MB |
+----------+----------+---------+---------+----+-----------+
| patroni1 | patroni1 | Leader  | running |  1 |           |
| patroni2 | patroni2 | Replica | running |  1 |         0 |
| patroni3 | patroni3 | Replica | running |  1 |         0 |
+----------+----------+---------+---------+----+-----------+
```

You can also view HAProxy statistics in your browser at `http://localhost:7000`.

---

## Verifying Read/Write Routing

### 1. Test Write Routing (Port 5000)

HAProxy routes write traffic on port `5000` to the current leader (`patroni1` initially). Connect and create a table:

```bash
psql -h localhost -p 5000 -U postgres -d postgres -c \
  "CREATE TABLE test_ha (id serial primary key, val text, created_at timestamp default now());"
```

Insert a row:
```bash
psql -h localhost -p 5000 -U postgres -d postgres -c \
  "INSERT INTO test_ha (val) VALUES ('Hello from Primary!');"
```

### 2. Test Read-Only Routing (Port 5001)

HAProxy routes read traffic on port `5001` to the replicas (`patroni2` and `patroni3` in round-robin):

```bash
psql -h localhost -p 5001 -U postgres -d postgres -c \
  "SELECT * FROM test_ha;"
```

If you try to write on port `5001`, you should get a read-only transaction error:
```bash
psql -h localhost -p 5001 -U postgres -d postgres -c \
  "INSERT INTO test_ha (val) VALUES ('This should fail');"
# ERROR: cannot execute INSERT in a read-only transaction
```

---

## Continuous Ingestion & Replication Testing

To make HA testing realistic, we have included an automated ingestion client (`scripts/ingest.py`) that continually generates mock sensor metrics and inserts them into the database once per second.

A helper bash script is provided to run this client in different ways:

### Running via Docker (Default)
By default, the ingestion client starts automatically in the background when you run `make up`. You can watch its continuous output using:
```bash
make client-logs
```

Alternatively, you can run a temporary interactive instance in a separate shell using the bash script:
```bash
./scripts/run_ingestion.sh docker
```

### Running Locally on the Host
If you prefer running the script on your host machine to simulate an external client, you can use:
```bash
./scripts/run_ingestion.sh local
```
*Note: This automatically handles virtualenv creation (`.venv`) and packages installation (`psycopg2-binary`) on the host.*

### Custom Connections
You can override the target connection variables in local mode:
```bash
DB_PORT=5000 DB_USER=postgres ./scripts/run_ingestion.sh local
```

---

## Simulating Failover

To test automatic failover, terminate the leader node:

```bash
docker compose stop patroni1
```

Now, monitor the cluster status from another node (e.g. `patroni2`):
```bash
docker compose exec patroni2 patronictl -c /etc/patroni/patroni.yml list
```

Observe that:
1.  One of the replicas (`patroni2` or `patroni3`) is automatically promoted to `Leader`.
2.  The remaining replica points replication to the new leader.
3.  Write connections on port `5000` automatically failover to the new leader (after HAProxy health checks update, which takes ~3 seconds).

Verify you can still insert rows through HAProxy on port `5000`:
```bash
psql -h localhost -p 5000 -U postgres -d postgres -c \
  "INSERT INTO test_ha (val) VALUES ('Hello after failover!');"
```

### Healing the Cluster

Bring the stopped node back online:
```bash
docker compose start patroni1
```

Run `patronictl list` again. You should see `patroni1` rejoin the cluster as a `Replica` and automatically catch up with replication.

---

## Interactive Containers Shells

For diagnostics and querying, you can jump inside any of the Patroni containers directly from the Makefile.

### Bash Shell
To open an interactive bash shell:
```bash
# Connect to patroni1 (default)
make bash

# Connect to a specific node (e.g. patroni2)
make bash NODE=patroni2
```

### PostgreSQL Interactive Shell (psql)
To connect to Postgres on any of the containers:
```bash
# Connect to patroni1 (default)
make psql

# Connect to a specific node (e.g. patroni3)
make psql NODE=patroni3
```

