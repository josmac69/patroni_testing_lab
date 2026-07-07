# Patroni Configuration & Operations Guide

This guide details the configuration of Patroni within this testing lab, the dynamic REST API endpoints, and a comprehensive cheat sheet for the `patronictl` command-line utility.

---

## Configuration Deep Dive (`patroni.yml`)

The configuration file at `patroni.yml` determines the bootstrap parameters, replication parameters, and consensus thresholds for the cluster. Below is a breakdown of key configuration blocks:

### 1. DCS (Distributed Consensus Store) Settings
Under the `bootstrap.dcs` section, we configure the core behavior of the cluster state coordinator:
```yaml
bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
```
*   **`ttl` (Time to Live)**: The length of time (in seconds) the leader lease exists in etcd. If the leader fails to renew it within this period, it is expired, and a failover is initiated.
*   **`loop_wait`**: The sleep interval (in seconds) between Patroni iteration loops. The leader attempts to renew its lease every `loop_wait` seconds.
*   **`retry_timeout`**: The timeout for etcd read/write operations. If etcd is slow or experiencing a brief outage, Patroni will retry for up to `retry_timeout` seconds before giving up.
*   **`maximum_lag_on_failover`**: The maximum database replication lag (in bytes) allowed for a standby replica to be considered for promotion. Here, it is set to `1,048,576` bytes (1 MB). If a standby lags by more than 1 MB, it will not be promoted to leader, preventing substantial data loss.

### 2. Replication & PostgreSQL Abstractions
*   **`use_pg_rewind: true`**: When a partitioned or crashed leader rejoins the cluster, its data timeline might have diverged from the newly promoted leader. `pg_rewind` rewinds the old leader's data directory to the point of divergence, allowing it to quickly catch up as a standby replica without performing a full base backup.
*   **`use_slots: true`**: Instructs PostgreSQL to use physical replication slots. This ensures that the primary node does not discard WAL segments required by replicas, preventing replication from breaking due to lag.
*   **Critical parameters**:
    *   `wal_level: replica`: Required for streaming replication.
    *   `hot_standby: "on"`: Allows standbys to accept read-only queries (critical for routing traffic on port `5001`).
    *   `hot_standby_feedback: "on"`: Prevents query cancellations on replicas by reporting active queries back to the primary.

---

## Patroni REST API Reference

Each Patroni agent runs a lightweight HTTP server on port `8008`. This API is used by HAProxy to check health and status, and can also be queried manually.

| HTTP Method | Endpoint | Return Status | Description |
| :--- | :--- | :--- | :--- |
| **GET** | `/primary` | `200 OK` / `503 Service Unavailable` | Returns `200` if the node is the running leader / primary. Returns `503` for replicas. Used by HAProxy port `5000`. |
| **GET** | `/replica` | `200 OK` / `503 Service Unavailable` | Returns `200` if the node is a running standby replica. Returns `503` for the leader. Used by HAProxy port `5001`. |
| **GET** | `/health` | `200 OK` / `503 Service Unavailable` | Returns `200` if the PostgreSQL instance is running, regardless of its role (primary or standby). |
| **GET** | `/patroni` | `200 OK` | Returns a JSON document containing the node's current configuration, replication state, lag, and role. |
| **GET** | `/cluster` | `200 OK` | Returns a JSON representation of the entire cluster membership and DCS status. |

### Diagnostic Query Example:
You can check a node's REST API from your local host or from another container using `curl`:
```bash
# Querying patroni1 from the host (if port is exposed or via docker exec)
docker compose exec patroni1 curl -s http://localhost:8008/patroni | jq .
```

---

## `patronictl` CLI Cheatsheet

`patronictl` is the command-line interface used to manage Patroni cluster states. Since our configuration is at `/etc/patroni/patroni.yml`, all commands must reference it using the `-c` flag.

### 1. Monitoring Cluster Status
```bash
docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml list
```
*   **Usage**: Displays membership, roles, running state, current timeline (TL), lag, and DCS lease status.
*   *Tip*: You can run this command with a watch loop to monitor live status:
    ```bash
    docker compose exec patroni1 watch patronictl -c /etc/patroni/patroni.yml list
    ```

### 2. Manual Switchover & Failover
If you need to perform scheduled maintenance on the current leader, you can trigger a controlled switchover:
```bash
docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml switchover
```
*   **Interactive Prompts**:
    1.  Specify the cluster name (e.g., `patroni-cluster`).
    2.  Specify the target node (leave blank to let Patroni choose the best candidate).
    3.  Specify the scheduled execution time (leave blank for immediate switchover).
    4.  Confirm the action.

*   **Non-interactive Option**:
    ```bash
    docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml switchover --master patroni1 --candidate patroni2 --scheduled now --force
    ```

### 3. Reinitializing a Broken Replica
If a replica fails to replicate, falls too far behind, or has corrupted WAL files, you can reinitialize it (which wipes its local data and clones a fresh copy from the primary):
```bash
docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml reinit patroni-cluster <node_name>
```
*   *Example*:
    ```bash
    docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml reinit patroni-cluster patroni3
    ```

### 4. Restarting Nodes
To restart the PostgreSQL service on a specific node without stopping the Patroni container itself:
```bash
docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml restart patroni-cluster <node_name>
```

### 5. Pausing and Resuming Autopilot
If you are performing complex maintenance (like major version upgrades) and want to prevent Patroni from triggering automatic failover if PostgreSQL restarts, you can **pause** the cluster:
```bash
# Pause automatic failover
docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml pause

# Resume automatic failover
docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml resume
```
*   **Note**: When paused, the cluster status list will display `Maintenance` next to the cluster state.

### 6. Modifying Cluster Configuration Dynamically
Instead of modifying `patroni.yml` on every single node and restarting, you can edit the cluster configuration directly in etcd. Patroni will apply changes dynamically to all nodes:
```bash
docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml edit-config
```
*   This opens a text editor showing the DCS configuration. Modify the YAML parameters, save, and exit. Patroni will validate the changes and apply them cluster-wide.
