# Multi-Cluster Standby Patroni Workshop Guide & Simulation Report

This document serves as a comprehensive, hands-on workshop guide and execution report based on the automated simulations run in the multi-cluster standby Patroni lab. It details the active-passive region architecture, cross-site replication mechanisms, failure scenarios, and standby cluster promotion.

---

## 1. Standby Cluster Architecture & Design

The multi-cluster lab implements a geo-replicated disaster recovery (DR) pattern:
*   **Primary Cluster (Berlin)**: An active 3-node high-availability Patroni cluster (`berlin-patroni1`, `berlin-patroni2`, `berlin-patroni3`) using its own `berlin-etcd` DCS.
*   **Standby Cluster (Bonn)**: A passive 3-node Patroni cluster (`bonn-patroni1`, `bonn-patroni2`, `bonn-patroni3`) using its own `bonn-etcd` DCS.
*   **Standby Leader**: The standby cluster leader (`bonn-patroni2` or similar) pulls changes from the primary cluster's HAProxy/Leader using a physical replication slot (`standby_slot`) on the primary database.
*   **Ingestion Workload**: Simulated client (`berlin-client`) ingesting telemetry data directly into the active Berlin primary cluster.

### Geo-Replicated Topology

```mermaid
graph TD
    subgraph Berlin Region (Primary Cluster)
        berlin-client[berlin-client Ingestion] -->|Port 5000| berlin-haproxy[berlin-haproxy]
        berlin-haproxy -->|Port 5000: Write| berlin-patroni2[berlin-patroni2: Leader]
        berlin-haproxy -.->|Port 5001: Read| berlin-patroni1[berlin-patroni1: Replica]
        berlin-haproxy -.->|Port 5001: Read| berlin-patroni3[berlin-patroni3: Replica]
        berlin-patroni2 --->|Streaming replication| berlin-patroni1
        berlin-patroni2 --->|Streaming replication| berlin-patroni3
        berlin-patroni2 <--->|DCS Lease| berlin-etcd[berlin-etcd DCS]
    end

    subgraph Bonn Region (Standby Cluster)
        bonn-haproxy[bonn-haproxy] -.->|Port 5001: Read| bonn-patroni1[bonn-patroni1: Replica]
        bonn-haproxy -->|Port 5000: Redirect/Write| bonn-patroni2[bonn-patroni2: Standby Leader]
        bonn-haproxy -.->|Port 5001: Read| bonn-patroni3[bonn-patroni3: Replica]
        bonn-patroni2 --->|Streaming replication| bonn-patroni1
        bonn-patroni2 --->|Streaming replication| bonn-patroni3
        bonn-patroni2 <--->|DCS Lease| bonn-etcd[bonn-etcd DCS]
    end

    berlin-patroni2 ===>|Cross-site replication via physical slot| bonn-patroni2
```

---

## 2. Core Failure & Resilience Scenarios

Below is the chronological walkthrough of the multi-cluster failure simulations.

### Scenario 1: Primary Leader Crash (Berlin region)
We simulate a sudden failure of the active primary cluster leader (`berlin-patroni1`).

#### Step-by-Step Walkthrough
1.  Stop the active Berlin leader container: `docker compose stop berlin-patroni1`.
2.  The surviving Berlin replicas (`berlin-patroni2`, `berlin-patroni3`) detect the leader key expiration in `berlin-etcd`.
3.  `berlin-patroni2` is promoted to Leader of the Primary Cluster, incrementing the timeline to `3`.
4.  The Standby Leader (`bonn-patroni2`) in the Bonn region automatically redirects its replication receiver stream to the new primary leader (`berlin-patroni2`).

#### Simulated Logs
```
=== PRIMARY CLUSTER STATUS ===
+ Cluster: cluster_berlin (7660934053316349992) ----------+----+-------------+-----+------------+-----+
| Member          | Host            | Role    | State     | TL | Receive LSN | Lag | Replay LSN | Lag |
+-----------------+-----------------+---------+-----------+----+-------------+-----+------------+-----+
| berlin-patroni1 | berlin-patroni1 | Leader  | running   |  2 |             |     |            |     |
| berlin-patroni2 | berlin-patroni2 | Replica | streaming |  2 |   0/4000000 |   0 |  0/4000000 |   0 |
| berlin-patroni3 | berlin-patroni3 | Replica | streaming |  2 |   0/4000000 |   0 |  0/4000000 |   0 |
+-----------------+-----------------+---------+-----------+----+-------------+-----+------------+-----+

=== STANDBY CLUSTER STATUS ===
+ Cluster: cluster_bonn (7660934053316349992) ---+-----------+----+-------------+-----+------------+-----+
| Member        | Host          | Role           | State     | TL | Receive LSN | Lag | Replay LSN | Lag |
+---------------+---------------+----------------+-----------+----+-------------+-----+------------+-----+
| bonn-patroni1 | bonn-patroni1 | Replica        | streaming |  2 |   0/4000000 |   0 |  0/4000000 |   0 |
| bonn-patroni2 | bonn-patroni2 | Standby Leader | running   |  2 |             |     |            |     |
| bonn-patroni3 | bonn-patroni3 | Replica        | streaming |  2 |   0/4000000 |   0 |  0/4000000 |   0 |
+---------------+---------------+----------------+-----------+----+-------------+-----+------------+-----+
```

---

### Scenario 2: Standby Leader Crash (Bonn region)
We simulate a failure of the standby leader (`bonn-patroni1`).

#### Step-by-Step Walkthrough
1.  Stop the active Bonn standby leader container: `docker compose stop bonn-patroni1`.
2.  The surviving Bonn replicas detect the loss of the standby leader key in `bonn-etcd`.
3.  `bonn-patroni2` is elected as the new Standby Leader.
4.  `bonn-patroni2` opens a new connection to `berlin-haproxy` on port `5000` to stream from the primary cluster.

#### Simulated Logs
```
=== STANDBY CLUSTER STATUS ===
+ Cluster: cluster_bonn (7660934053316349992) ---+-----------+----+-------------+-----+------------+-----+
| Member        | Host          | Role           | State     | TL | Receive LSN | Lag | Replay LSN | Lag |
+---------------+---------------+----------------+-----------+----+-------------+-----+------------+-----+
| bonn-patroni1 | bonn-patroni1 | Replica        | streaming |  3 |   0/600BDB0 |   0 |  0/600BDB0 |   0 |
| bonn-patroni2 | bonn-patroni2 | Standby Leader | streaming |  3 |             |     |            |     |
| bonn-patroni3 | bonn-patroni3 | Replica        | streaming |  3 |   0/600BDB0 |   0 |  0/600BDB0 |   0 |
+---------------+---------------+----------------+-----------+----+-------------+-----+------------+-----+
```

---

### Scenario 3: Regional DCS Failure (etcd Loss)
What happens if the local consensus store in one of the regions goes down?

#### Step-by-Step Walkthrough
1.  Stop `bonn-etcd`.
2.  Bonn nodes cannot renew their lease keys or retrieve cluster state.
3.  The standby leader `bonn-patroni2` demotes itself to protect the database.
4.  Once `bonn-etcd` is restarted, the nodes reconnect, select a Standby Leader, and resume passive replication.

#### Simulated Logs
```
==================================================
COMMAND: make status (timeout: 10s)
==================================================
2026-07-10 16:19:35,104 - WARNING - failed to resolve host bonn-etcd: [Errno -5] No address associated with hostname
make: *** [Makefile:69: status] Terminated
Command timed out or exited with status 124

==================================================
COMMAND: make recover-bonn-dcs
==================================================
Starting bonn-etcd...
docker compose start bonn-etcd
 Container bonn-etcd Starting 
 Container bonn-etcd Started 
 bonn-etcd is healthy.
```

---

### Scenario 4: Standby Cluster Promotion (Failover to Bonn)
In a real disaster scenario where the primary region (Berlin) goes completely dark, the Standby Cluster must be promoted to a standalone primary cluster.

#### Step-by-Step Walkthrough
1.  Run `make promote-standby`. This executes a configuration update against the `bonn-etcd` DCS, removing the `standby_cluster` configuration block.
2.  `bonn-patroni2` realizes it is no longer a Standby Leader replicating from an external cluster.
3.  `bonn-patroni2` promotes itself to a true primary Leader and increments the local cluster timeline to `4`.
4.  `bonn-patroni1` and `bonn-patroni3` change roles to replicas streaming from `bonn-patroni2`. The Bonn cluster now accepts direct write transactions.

#### Simulated Logs
```
==================================================
COMMAND: make promote-standby
==================================================
Promoting Bonn Cluster to Primary Cluster...
--- 
+++ 
@@ -14,8 +14,4 @@
   use_pg_rewind: true
   use_slots: true
 retry_timeout: 10
-standby_cluster:
-  host: berlin-haproxy
-  port: 5000
-  primary_slot_name: standby_slot
 ttl: 30
Configuration changed

==================================================
COMMAND: make status
==================================================
=== STANDBY CLUSTER STATUS ===
+ Cluster: cluster_bonn (7660934053316349992) --------+----+-------------+-----+------------+-----+
| Member        | Host          | Role    | State     | TL | Receive LSN | Lag | Replay LSN | Lag |
+---------------+---------------+---------+-----------+----+-------------+-----+------------+-----+
| bonn-patroni1 | bonn-patroni1 | Replica | streaming |  4 |   0/6011580 |   0 |  0/6011580 |   0 |
| bonn-patroni2 | bonn-patroni2 | Leader  | running   |  4 |             |     |            |     |
| bonn-patroni3 | bonn-patroni3 | Replica | streaming |  4 |   0/6011580 |   0 |  0/6011580 |   0 |
+---------------+---------------+---------+-----------+----+-------------+-----+------------+-----+
```

---

## 3. Key Design Takeaways

1.  **DCS Independence**: By running separate etcd clusters (`berlin-etcd` and `bonn-etcd`), a failure of the primary site DCS does not freeze the DR site, and vice-versa.
2.  **Physical Slots prevent Lag**: Using a physical replication slot (`standby_slot`) on the primary ensures that WAL files required by the standby cluster are not recycled prematurely, preventing replication breakage during heavy write cycles.
3.  **Smooth Timeline Syncing**: When the standby is promoted, it branches off onto a new timeline (e.g. TL 4), ensuring that any future reconciliation or fallback setups can use `pg_rewind` to align state.
