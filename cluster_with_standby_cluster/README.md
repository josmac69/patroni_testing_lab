# Patroni Active-Standby Testing Lab

This testing lab demonstrates a high-availability multi-site topology using two independent Patroni-managed PostgreSQL clusters. 

- **Primary (Active) Cluster**: A 3-node HA PostgreSQL cluster with its own `etcd` DCS, accepting client writes and reads.
- **Standby Cluster**: An independent 3-node Patroni cluster with its own separate `etcd` DCS, configured to replicate all data from the primary cluster using streaming replication.

---

## Architecture Diagram

```mermaid
flowchart TD
    subgraph Primary Site [Primary Cluster (scope: cluster_berlin)]
        berlin-etcd[(berlin-etcd)]
        berlin-patroni1[berlin-patroni1\nLeader]
        berlin-patroni2[berlin-patroni2\nReplica]
        berlin-patroni3[berlin-patroni3\nReplica]
        berlin-haproxy[berlin-haproxy\nWrite: 5000 / Read: 5001]
        
        berlin-patroni1 <--> berlin-etcd
        berlin-patroni2 <--> berlin-etcd
        berlin-patroni3 <--> berlin-etcd
        
        berlin-patroni2 -.->|Replication| berlin-patroni1
        berlin-patroni3 -.->|Replication| berlin-patroni1
        
        berlin-haproxy -->|GET /primary| berlin-patroni1
    end

    subgraph Standby Site [Standby Cluster (scope: cluster_bonn)]
        bonn-etcd[(bonn-etcd)]
        bonn-patroni1[bonn-patroni1\nStandby Leader]
        bonn-patroni2[bonn-patroni2\nReplica]
        bonn-patroni3[bonn-patroni3\nReplica]
        bonn-haproxy[bonn-haproxy\nWrite/Leader: 6000 / Read: 6001]
        
        bonn-patroni1 <--> bonn-etcd
        bonn-patroni2 <--> bonn-etcd
        bonn-patroni3 <--> bonn-etcd
        
        bonn-patroni2 -.->|Replication| bonn-patroni1
        bonn-patroni3 -.->|Replication| bonn-patroni1
        
        bonn-haproxy -->|GET /leader| bonn-patroni1
    end

    client(Ingestion Client) -->|Writes| berlin-haproxy
    bonn-patroni1 -.->|Streaming Replication| berlin-haproxy
```

---

## Port Allocations

To avoid port conflicts on the host, the resources are partitioned as follows:

| Service | Internal Port | Host Port | Role / Endpoint |
| :--- | :--- | :--- | :--- |
| **berlin-etcd** | `2379` | `2379` | Primary Cluster DCS client port |
| **bonn-etcd** | `2379` | `2389` | Standby Cluster DCS client port |
| **berlin-haproxy** | `5000` | `5000` | Primary Write Port (`GET /primary`) |
| **berlin-haproxy** | `5001` | `5001` | Primary Read Port (`GET /replica`) |
| **berlin-haproxy** | `7000` | `7000` | Primary Stats Web Interface |
| **bonn-haproxy** | `5000` | `6000` | Standby Leader Write/Read Port (`GET /leader`) |
| **bonn-haproxy** | `5001` | `6001` | Standby Read Port (`GET /replica`) |
| **bonn-haproxy** | `7000` | `8000` | Standby Stats Web Interface |

---

## Lab Commands

### 1. Bootstrapping the Lab
Run the sequential bootstrap orchestrator to build the environment in a clean, race-free order:
```bash
make bootstrap
```

### 2. Status Monitoring
View the active membership, replication state, and LSN lag for both clusters side-by-side:
```bash
make status
```

### 3. Database Testing
- **Write to Primary Cluster** (Default is 1 record, override with `NUM`):
  ```bash
  make write-test
  make write-test NUM=50
  ```
- **Read from Standby Cluster** (Verifies data replication):
  ```bash
  make read-test-standby
  ```
- **Write to Standby Cluster** (Should fail with a read-only transaction error):
  ```bash
  make write-test-standby
  ```
- **Measure Data Loss / Outages (RATE/DURATION)**:
  ```bash
  make measure-loss-rate
  make measure-loss-rate RATE=120 DURATION=60
  ```


### 4. Running Triage Audits
Analyze the health of either cluster using the container-aware triage script (specify `CLUSTER`):
```bash
make triage CLUSTER=berlin
make triage CLUSTER=bonn
```

### 5. Promoting the Standby Cluster
Promote the Standby Cluster to an independent primary/active cluster:
```bash
make promote-standby
```

---

## Behind the Scenes

### How Standby Clusters Bootstrap
1. When `bonn-patroni1` starts, it reads `patroni-bonn.yml`.
2. It detects the `standby_cluster` block under `bootstrap.dcs`.
3. Instead of initializing a blank PostgreSQL cluster, it initiates a `pg_basebackup` clone from `berlin-haproxy:5000`.
4. Once cloned, it starts up as the `Standby Leader`.
5. It begins streaming from the primary cluster and registers a replication slot called `standby_slot` on the primary to track its lag.
6. The replica nodes `bonn-patroni2` and `bonn-patroni3` join and clone their data directly from `bonn-patroni1` (cascading replication).

### How Standby Promotion Works
When `make promote-standby` is executed:
1. It updates the DCS config in `bonn-etcd` to remove the `standby_cluster` block:
   ```bash
   patronictl edit-config --set standby_cluster=null --force
   ```
2. The standby leader (`bonn-patroni1`) detects this DCS update.
3. It breaks replication from the primary cluster and promotes PostgreSQL to a standalone primary database.
4. It changes its timeline from the primary timeline to a new, diverged timeline.
5. The replicas `bonn-patroni2` and `bonn-patroni3` follow the timeline transition and continue streaming from the newly promoted leader.
6. The cluster is now fully writable (verifiable by running `make write-test-standby`).

---

## Measuring RPO/RTO Data Loss (Continuous Inserts)

To measure actual data loss (Recovery Point Objective - RPO) and outage duration (Recovery Time Objective - RTO) during standby promotion or failovers:

1. **Start the Continuous Insert Harness** in a dedicated terminal window:
   ```bash
   # Run with 120 inserts per minute (2 inserts per second) for 60 seconds
   make measure-loss-rate RATE=120 DURATION=60
   ```
2. **Trigger the failure scenario or promotion** in a second terminal window while the inserts are running:
   ```bash
   # E.g., promote the standby cluster:
   make promote-standby
   # Or simulate primary leader failure:
   make simulate-berlin-leader-failure
   ```
3. **Inspect the Harness Terminal Output**:
   The harness will log each successful insert, output warnings when writes fail during the outage, report the RTO (how long the database was unavailable), and count any RPO violations (acknowledged writes that were lost during the failover/crash).

