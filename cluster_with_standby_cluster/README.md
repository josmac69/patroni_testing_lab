# Patroni Active-Standby Testing Lab

This testing lab demonstrates a high-availability multi-site topology using two independent Patroni-managed PostgreSQL clusters. 

- **Primary (Active) Cluster**: A 3-node HA PostgreSQL cluster with its own `etcd` DCS, accepting client writes and reads.
- **Standby Cluster**: An independent 3-node Patroni cluster with its own separate `etcd` DCS, configured to replicate all data from the primary cluster using streaming replication.

---

## Architecture Diagram

```mermaid
flowchart TD
    subgraph Primary Site [Primary Cluster (scope: primary-cluster)]
        primary-etcd[(primary-etcd)]
        primary-patroni1[primary-patroni1\nLeader]
        primary-patroni2[primary-patroni2\nReplica]
        primary-patroni3[primary-patroni3\nReplica]
        primary-haproxy[primary-haproxy\nWrite: 5000 / Read: 5001]
        
        primary-patroni1 <--> primary-etcd
        primary-patroni2 <--> primary-etcd
        primary-patroni3 <--> primary-etcd
        
        primary-patroni2 -.->|Replication| primary-patroni1
        primary-patroni3 -.->|Replication| primary-patroni1
        
        primary-haproxy -->|GET /primary| primary-patroni1
    end

    subgraph Standby Site [Standby Cluster (scope: standby-cluster)]
        standby-etcd[(standby-etcd)]
        standby-patroni1[standby-patroni1\nStandby Leader]
        standby-patroni2[standby-patroni2\nReplica]
        standby-patroni3[standby-patroni3\nReplica]
        standby-haproxy[standby-haproxy\nWrite/Leader: 6000 / Read: 6001]
        
        standby-patroni1 <--> standby-etcd
        standby-patroni2 <--> standby-etcd
        standby-patroni3 <--> standby-etcd
        
        standby-patroni2 -.->|Replication| standby-patroni1
        standby-patroni3 -.->|Replication| standby-patroni1
        
        standby-haproxy -->|GET /leader| standby-patroni1
    end

    client(Ingestion Client) -->|Writes| primary-haproxy
    standby-patroni1 -.->|Streaming Replication| primary-haproxy
```

---

## Port Allocations

To avoid port conflicts on the host, the resources are partitioned as follows:

| Service | Internal Port | Host Port | Role / Endpoint |
| :--- | :--- | :--- | :--- |
| **primary-etcd** | `2379` | `2379` | Primary Cluster DCS client port |
| **standby-etcd** | `2379` | `2389` | Standby Cluster DCS client port |
| **primary-haproxy** | `5000` | `5000` | Primary Write Port (`GET /primary`) |
| **primary-haproxy** | `5001` | `5001` | Primary Read Port (`GET /replica`) |
| **primary-haproxy** | `7000` | `7000` | Primary Stats Web Interface |
| **standby-haproxy** | `5000` | `6000` | Standby Leader Write/Read Port (`GET /leader`) |
| **standby-haproxy** | `5001` | `6001` | Standby Read Port (`GET /replica`) |
| **standby-haproxy** | `7000` | `8000` | Standby Stats Web Interface |

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

### 4. Running Triage Audits
Analyze the health of either cluster using the container-aware triage script (specify `CLUSTER`):
```bash
make triage CLUSTER=primary
make triage CLUSTER=standby
```

### 5. Promoting the Standby Cluster
Promote the Standby Cluster to an independent primary/active cluster:
```bash
make promote-standby
```

---

## Behind the Scenes

### How Standby Clusters Bootstrap
1. When `standby-patroni1` starts, it reads `patroni-standby.yml`.
2. It detects the `standby_cluster` block under `bootstrap.dcs`.
3. Instead of initializing a blank PostgreSQL cluster, it initiates a `pg_basebackup` clone from `primary-haproxy:5000`.
4. Once cloned, it starts up as the `Standby Leader`.
5. It begins streaming from the primary cluster and registers a replication slot called `standby_slot` on the primary to track its lag.
6. The replica nodes `standby-patroni2` and `standby-patroni3` join and clone their data directly from `standby-patroni1` (cascading replication).

### How Standby Promotion Works
When `make promote-standby` is executed:
1. It updates the DCS config in `standby-etcd` to remove the `standby_cluster` block:
   ```bash
   patronictl edit-config --set standby_cluster=null --force
   ```
2. The standby leader (`standby-patroni1`) detects this DCS update.
3. It breaks replication from the primary cluster and promotes PostgreSQL to a standalone primary database.
4. It changes its timeline from the primary timeline to a new, diverged timeline.
5. The replicas `standby-patroni2` and `standby-patroni3` follow the timeline transition and continue streaming from the newly promoted leader.
6. The cluster is now fully writable (verifiable by running `make write-test-standby`).
