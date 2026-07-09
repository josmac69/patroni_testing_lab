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

### Core Lab Commands
*   **`make up`**: Build the custom images and start the cluster in the background.
*   **`make down`**: Stop the running cluster containers.
*   **`make clean`**: Stop the cluster and destroy the named PostgreSQL volumes (resets all data!).
*   **`make bootstrap`**: Run the realistic sequential cluster bootstrap process.
*   **`make status`**: Display the active Patroni cluster membership, role, lag, and timeline details.
*   **`make ps`**: Show the docker container statuses.
*   **`make logs`**: Stream the logs of all containers.
*   **`make failover`**: Run the manual Patroni failover wizard.
*   **`make write-test`**: Run a test INSERT statement via the HAProxy write-only port `5000`.
*   **`make read-test`**: Run a test SELECT statement via the HAProxy read-only port `5001`.
*   **`make bash`**: Open a root bash shell inside the selected container (default: `NODE=patroni1`).
*   **`make psql`**: Open a `psql` shell inside the selected container (default: `NODE=patroni1`).

### Triage & Diagnosis Commands
*   **`make triage`**: Run the deep triage and audit script (`scripts/patroni_deep_triage.sh`) to detect health anomalies, configuration errors, and print remediation suggestions.
*   **`make dcs-dump`**: Dump all keys and metadata currently held in `etcd` (the DCS store) under the `/service/patroni-cluster` namespace.

### Simulation & Failure Commands
*   **`make simulate-leader-failure`**: Detects which Patroni container is the current leader and stops it (`docker compose stop`), simulating a hard crash.
*   **`make simulate-dcs-failure`**: Stops the `etcd` container to simulate DCS quorum loss.
*   **`make simulate-network-partition`**: Disconnects the current leader node from the Docker bridge network to simulate a network split.
*   **`make pause-cluster`**: Pauses Patroni auto-failover/supervision (maintenance mode).

### Recovery & Repair Commands
*   **`make recover-node NODE=<node>`**: Restarts a stopped Patroni node container (e.g. `NODE=patroni1`).
*   **`make recover-dcs`**: Restarts the `etcd` container and blocks until it reports healthy.
*   **`make recover-network-partition`**: Reconnects all cluster nodes back to the network, healing any active network splits.
*   **`make resume-cluster`**: Resumes cluster supervision.
*   **`make reinit-replica NODE=<node>`**: Forces a full re-clone and sync of a replica from the current leader.

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

HAProxy routes write traffic on port `5000` to the current leader (`patroni1` initially). You can run a test write using the Makefile:

```bash
make write-test
```

Or run it manually:
```bash
psql -h localhost -p 5000 -U postgres -d postgres -c \
  "INSERT INTO sensor_readings (sensor_name, reading_value) VALUES ('manual_test_sensor', 42.0);"
```

### 2. Test Read-Only Routing (Port 5001)

HAProxy routes read traffic on port `5001` to the replicas (`patroni2` and `patroni3` in round-robin). Run the test read:

```bash
make read-test
```

Or run it manually:
```bash
psql -h localhost -p 5001 -U postgres -d postgres -c \
  "SELECT * FROM sensor_readings ORDER BY id DESC LIMIT 5;"
```

If you try to write on port `5001`, you should get a read-only transaction error:
```bash
psql -h localhost -p 5001 -U postgres -d postgres -c \
  "INSERT INTO sensor_readings (sensor_name, reading_value) VALUES ('fail_sensor', 0.0);"
# ERROR: cannot execute INSERT in a read-only transaction
```

---

## Continuous Ingestion & Replication Testing

To make HA testing realistic, we have included an automated ingestion client (`scripts/ingest.py`) that continually generates mock sensor metrics and inserts them into the database once per second.

A helper bash script is provided to run this client in different ways:

### Running via Docker (Default)
By default, the ingestion client starts automatically in the background when you run `make up` or `make bootstrap`. You can watch its continuous output using:
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

## Failures Simulation & Triage Walkthrough

This section describes how to simulate common cluster failures, diagnose them using `make triage` and `make status`, and perform the recovery.

### Scenario 1: Leader Node Crash (Automatic Failover)

**1. Simulation**
Simulate a hard crash of the current leader node (e.g. `patroni1`):
```bash
make simulate-leader-failure
```

**2. Diagnosis**
- Check the cluster membership status:
  ```bash
  make status
  ```
  You will see that the stopped node is marked as `offline` or `stopped`, and one of the replicas has been promoted to `Leader` (e.g., `patroni2` or `patroni3`).
- Run the deep triage tool:
  ```bash
  make triage
  ```
  The triage report will flag that the container is stopped and will show the log forensics highlighting the recent promotion of the replica.
- Verify that write connections on port `5000` still work (they automatically route to the new leader via HAProxy):
  ```bash
  make write-test
  ```

**3. Repair**
Bring the stopped node back online to rejoin the cluster:
```bash
make recover-node NODE=patroni1
```
Monitor the status; the node will rejoin as a `Replica`, clone/sync metadata, and catch up with replication.

---

### Scenario 2: DCS Quorum Loss (Read-Only Safety Fencing)

Without a healthy consensus store (DCS), Patroni cannot guarantee which node should be the leader and will demote the active leader to prevent split-brain writes.

**1. Simulation**
Stop the `etcd` consensus container:
```bash
make simulate-dcs-failure
```

**2. Diagnosis**
- Check the cluster status:
  ```bash
  make status
  ```
  This will fail with an error because the DCS is unreachable.
- Run the deep triage tool:
  ```bash
  make triage
  ```
  The triage script will flag the etcd endpoints as `CLOSED` and warning about the unreachable DCS.
- Verify write routing:
  ```bash
  make write-test
  ```
  This will fail. Because etcd is down, Patroni demotes the leader, making all PostgreSQL nodes read-only (or shut down entirely depending on configuration).

**3. Repair**
Restart the etcd container and wait for it to be healthy:
```bash
make recover-dcs
```
Once etcd is online, Patroni nodes will automatically re-acquire lease states and election rules, electing a new leader and returning the cluster to service.

---

### Scenario 3: Leader Network Partition (Demotion & Fencing)

A network partition cuts the leader off from the replicas and the DCS. The leader must quickly demote itself to avoid split-brain writes on the isolated network segment.

**1. Simulation**
Disconnect the active leader node from the Docker network:
```bash
make simulate-network-partition
```

**2. Diagnosis**
- Run `make status`. The cluster view will report the isolated leader as offline, and the remaining nodes will have elected a new leader.
- Run deep triage:
  ```bash
  make triage
  ```
  The triage tool will notice the mismatch and flag the partition.
- Test client writes:
  ```bash
  make write-test
  ```
  Client writes continue normally because HAProxy dynamically routes write traffic to the new leader on the reachable network segment.

**3. Repair**
Heal the network partition:
```bash
make recover-network-partition
```
The partitioned node will be reconnected to the network, discover that another node has assumed leadership, demote its local PostgreSQL timeline, and automatically catch up with the new leader.

---

### Scenario 4: Cluster Pausing (Maintenance Mode)

When performing migrations or troubleshooting, you may want to freeze the cluster and prevent automatic failover.

**1. Simulation**
Pause Patroni supervision:
```bash
make pause-cluster
```

**2. Diagnosis**
- Check status:
  ```bash
  make status
  ```
  The header will show: `Cluster: patroni-cluster (paused)`.
- Run triage:
  ```bash
  make triage
  ```
  Triage will report a critical issue: `Cluster is PAUSED — the HA loop is disabled: NO automatic failover`.
- If you stop a node now, no failover will occur.

**3. Repair**
Resume Patroni supervision:
```bash
make resume-cluster
```

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


