# HAProxy Load Balancing & Routing Guide

This document describes the configuration and operational mechanisms of the HAProxy load balancer in this Patroni cluster environment.

---

## HAProxy Role in the Cluster

In a Patroni highly available cluster, PostgreSQL nodes dynamically change roles (e.g., a primary becomes a replica, or a replica is promoted to primary). 
Clients cannot connect directly to specific hostnames (like `patroni1`) because those hostnames do not represent fixed roles. 

Instead, **HAProxy** serves as a reverse proxy that:
1.  Exposes fixed entry points (ports `5000` and `5001`) for the application client.
2.  Dynamically discovers which node is the current Leader and which are the Replicas by query-polling Patroni's REST API.
3.  Routes connections to the appropriate PostgreSQL instances.

---

## Configuration Breakdown (`haproxy.cfg`)

Below is an analysis of how the routing and health-checking behaviors are configured in `haproxy.cfg`.

### 1. Global & Defaults Settings
```haproxy
defaults
    mode tcp
    retries 2
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 2s
```
*   **`mode tcp`**: Configures HAProxy to operate at Layer 4 (TCP). HAProxy does not parse or modify PostgreSQL protocol packets; it acts as a transparent pipeline between the client driver and the database.
*   **`timeout client 30m` & `timeout server 30m`**: Since database connections are typically long-lived, we set a high inactivity timeout (30 minutes) to prevent HAProxy from cutting off idle client sessions.
*   **`timeout check 2s`**: The health check queries must return a response within 2 seconds, or they are marked as failed.

### 2. HAProxy Stats Web Page (Port `7000`)
```haproxy
frontend stats
    mode http
    bind 0.0.0.0:7000
    stats enable
    stats uri /
    stats refresh 5s
```
*   Exposes a web interface at `http://localhost:7000`.
*   Displays the current status of each backend database node, connection counts, fail history, and active throughput. It refreshes automatically every 5 seconds.

### 3. Write-Only Backend (Port `5000`)
```haproxy
frontend postgres_write_front
    bind 0.0.0.0:5000
    default_backend postgres_write_back

backend postgres_write_back
    mode tcp
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server patroni1 patroni1:5432 maxconn 100 check port 8008
    server patroni2 patroni2:5432 maxconn 100 check port 8008
    server patroni3 patroni3:5432 maxconn 100 check port 8008
```
*   **Dynamic Health Check**: Even though routing is TCP, HAProxy uses HTTP to perform health checks:
    *   `option httpchk GET /primary`: HAProxy requests `/primary` from the Patroni REST API running on port `8008` (specified by `check port 8008` on each server line).
    *   `http-check expect status 200`: Only the node that is the current active primary returns `200 OK`. Replicas return `503 Service Unavailable` and are excluded from the write backend pool.
*   **`default-server` parameters**:
    *   `inter 3s`: Polls the health check API once every 3 seconds.
    *   `fall 3`: A node must fail 3 consecutive checks (9 seconds total) to be marked as offline/down.
    *   `rise 2`: A node must pass 2 consecutive checks (6 seconds total) to be marked as online/up.

### 4. Read-Only Backend (Port `5001`)
```haproxy
frontend postgres_read_front
    bind 0.0.0.0:5001
    default_backend postgres_read_back

backend postgres_read_back
    mode tcp
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 check port 8008
    server patroni1 patroni1:5432 maxconn 100 check port 8008
    server patroni2 patroni2:5432 maxconn 100 check port 8008
    server patroni3 patroni3:5432 maxconn 100 check port 8008
```
*   **Load Balancing**: `balance roundrobin` routes incoming read-only sessions sequentially across all active backend servers in the pool.
*   **Dynamic Health Check**:
    *   `option httpchk GET /replica`: Queries the replica health endpoint.
    *   Replicas return `200 OK` and are included in the pool.
    *   The primary returns `503 Service Unavailable`, preventing read-only query overhead on the active write leader.

---

## Critical Mechanism: Connection Termination (`on-marked-down shutdown-sessions`)

In Layer 4 TCP proxying, once a connection is established, HAProxy does not inspect the data passing through. If a leader node fails or is demoted, existing TCP connections to that node could theoretically remain open (hanging or waiting for timeouts) because the socket has not been cleanly closed at the network layer.

To prevent this:
*   We use the **`on-marked-down shutdown-sessions`** directive on the write backend.
*   **Behavior**: The moment a server fails its health checks and is marked `DOWN` by HAProxy, HAProxy **immediately terminates all active client sessions** connected to that server.
*   **Benefit**: This forces the database client to receive a network drop. The client's connection pool/driver then instantly initiates a reconnect attempt. On reconnect, HAProxy routes the client to the newly promoted leader (which has now been marked `UP`), minimizing wait time and avoiding write failures.

---

## Failover Latency Calculation

The total duration before a client is successfully routed to the new leader during a failover depends on:
1.  **DCS Lease TTL**: The time it takes for etcd to release the leader key (up to `30s` in `patroni.yml`).
2.  **Promotion Duration**: The time it takes the selected replica to run `pg_ctl promote` (typically `<1s`).
3.  **HAProxy Poll Interval**: The time before HAProxy detects the new primary (`inter 3s * rise 2` = `6s` maximum).

In practice, a full failover from a physical crash takes:
$$\text{Max Latency} \approx \text{DCS TTL (30s)} + \text{Promotion (1s)} + \text{HAProxy detection (6s)} \approx 37\text{ seconds}$$

If the failover is a manual switchover (`patronictl switchover`), the old leader voluntarily releases the etcd lease immediately, reducing the failover latency to:
$$\text{Manual Latency} \approx \text{Promotion (1s)} + \text{HAProxy detection (6s)} \approx 7\text{ seconds}$$
