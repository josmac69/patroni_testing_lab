# Patroni PostgreSQL Testing Lab

Welcome to the Patroni PostgreSQL Testing Lab! This repository contains sandbox environments designed to simulate, diagnose, and validate high-availability PostgreSQL topologies managed by Patroni in containerized Docker environments.

---

## Lab Topologies

The repository is organized into two separate testing setups, each targeting a different architectural scenario:

### 1. Classic 3-Node HA Cluster (`classic_3_nodes/`)
A single, high-availability PostgreSQL cluster featuring:
- **3 Database Nodes** managed by Patroni.
- **1 etcd Container** acting as the Distributed Configuration Store (DCS).
- **1 HAProxy Load Balancer** providing unified read/write endpoints.
- **1 Continuous Ingestion Client** seeding real-time mock data.
- **Testing Scenarios**: Automatic failover, DCS quorum loss, network partitions, cluster maintenance mode (pause/resume), and replica re-initialization.
- **👉 [Classic 3-Node Readme](./classic_3_nodes/README.md)**

---

### 2. Multi-Cluster Active-Standby Lab (`cluster_with_standby_cluster/`)
A complex multi-site or disaster recovery simulation featuring two completely independent Patroni clusters:
- **Primary Cluster (`cluster_berlin`)**: 3 database nodes with a dedicated `berlin-etcd` DCS, accepting active reads and writes.
- **Standby Cluster (`cluster_bonn`)**: 3 database nodes with a dedicated `bonn-etcd` DCS, replication-fenced (read-only) and streaming data from the primary's HAProxy.
- **HAProxy Routing**: Two independent load balancers routing queries for each site.
- **Testing Scenarios**: Physical replication slot tracking, cross-cluster replication lag, write-fencing validation, and dynamic standby cluster promotion.
- **👉 [Active-Standby Readme](./cluster_with_standby_cluster/README.md)**

---

### 3. Patroni Lab Enhancements (`patroni_lab_enhancements/`)
A production-grade, learning-first sandbox containing:
- **3-Node etcd DCS Quorum**: A genuine 3-node etcd cluster to demonstrate quorum loss mechanics.
- **Observability Stack**: Pre-configured Prometheus and Grafana dashboards for real-time metric analysis.
- **pgBackRest Integration**: Out-of-the-box backups, stanza creation, and replica rebuilds via a shared backup repository.
- **Upgrade Runbooks**: Automated scripts for major PostgreSQL version upgrades.
- **Chaos Injection**: Detailed guides for Toxiproxy fault simulation (e.g. asymmetrical partitions).
- **👉 [Patroni Lab Enhancements Readme](./patroni_lab_enhancements/README.md)**

---

## Directory Structure

```text
patroni_testing_lab/
├── classic_3_nodes/               # Setup 1: Single 3-node HA cluster
│   ├── Makefile                   # Lab automation
│   ├── README.md                  # Scenario guide & documentation
│   ├── docker-compose.yml         # Container orchestration
│   ├── patroni.yml                # Patroni configuration
│   └── scripts/                   # Simulation & triage scripts
│
└── cluster_with_standby_cluster/  # Setup 2: Multi-cluster standby lab
    ├── Makefile                   # Lab automation
    ├── README.md                  # Standby & promotion guide
    ├── docker-compose.yml         # Orchestration for both clusters (8 services)
    ├── patroni-berlin.yml         # Configuration for active cluster (cluster_berlin)
    ├── patroni-bonn.yml           # Configuration for standby cluster (cluster_bonn)
    └── scripts/                   # Sequential bootstrap & triage scripts
│
└── patroni_lab_enhancements/      # Setup 3: Production-grade lab enhancements
    ├── enhanced_3_nodes/          # Flagship lab with 3 etcd nodes, Grafana, and Prometheus
    ├── chaos/                     # Toxiproxy and fault injection guides
    ├── backup_pgbackrest/         # pgBackRest integration lab and PITR guides
    ├── upgrade_pg_major/          # Major version upgrade automation
    └── ci/                        # Example GitHub Actions self-test validation
```

---

## Host Port Assignments

To allow running both labs simultaneously or independently without conflict, host ports are allocated as follows:

| Component | Classic 3-Node | Active-Standby (Primary) | Active-Standby (Standby) |
| :--- | :--- | :--- | :--- |
| **DCS Client (`etcd`)** | `2379` | `2379` | `2389` |
| **HAProxy Write Port** | `5000` | `5000` | `6000` *(Read-only until promoted)* |
| **HAProxy Read Port** | `5001` | `5001` | `6001` |
| **HAProxy Stats UI** | `7000` | `7000` | `8000` |

---

## Quick Start

### Running the Classic 3-Node Lab
1. Navigate to the directory:
   ```bash
   cd classic_3_nodes
   ```
2. Bootstrap the environment:
   ```bash
   make bootstrap
   ```
3. Check the status of the Patroni nodes:
   ```bash
   make status
   ```

### Running the Multi-Cluster Standby Lab
1. Navigate to the directory:
   ```bash
   cd cluster_with_standby_cluster
   ```
2. Run the sequential bootstrap orchestrator:
   ```bash
   make bootstrap
   ```
3. Inspect both cluster statuses:
   ```bash
   make status
   ```
4. Verify write-fencing:
   ```bash
   make write-test-standby  # Should fail with read-only error
   ```
5. Promote the standby cluster:
   ```bash
   make promote-standby
   ```

### Running the Patroni Lab Enhancements
1. Navigate to the directory:
   ```bash
   cd patroni_lab_enhancements/enhanced_3_nodes
   ```
2. Bootstrap the environment:
   ```bash
   make up
   ```
3. Run an automated scenario (e.g., failover):
   ```bash
   ./scripts/scenario_failover.sh
   ```
4. Access dashboards:
   - **Grafana**: [http://localhost:3000](http://localhost:3000) (admin/admin)
   - **Prometheus**: [http://localhost:9090](http://localhost:9090)
