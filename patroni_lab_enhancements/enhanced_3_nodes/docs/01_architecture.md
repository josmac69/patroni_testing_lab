# Architecture

## Components

| Component | Count | Role |
|---|---|---|
| Patroni + PostgreSQL | 3 | `patroni1..3`, REST API on :8008, PostgreSQL on :5432 |
| etcd | 3 | genuine Raft quorum (`etcd1..3`), client API :2379 (v3 only) |
| HAProxy | 1 | :5000 writes, :5001 reads, :7000 stats, :8404 metrics |
| Prometheus | 1 | scrapes Patroni, postgres_exporter, etcd, HAProxy every 5 s |
| Grafana | 1 | provisioned dashboard "Patroni Lab Overview" |
| postgres_exporter | 3 | one sidecar per PostgreSQL node |
| ingestion client | 1 | one INSERT per second through :5000 |

## Why a 3-node etcd cluster

A single etcd node can only teach "DCS down". A 3-node quorum can teach the
distinction that actually matters in production:

* **1 of 3 down** — quorum holds; Patroni never notices. Resilience of the
  control plane is a property of the DCS deployment, not of Patroni.
* **2 of 3 down** — quorum lost; the leader cannot refresh its key and demotes
  itself to read-only within `ttl` seconds. Availability is sacrificed for
  the split-brain guarantee, unless `failsafe_mode` is enabled.

## Design decisions worth explaining in a training session

1. **Health checks target Patroni, not PostgreSQL.** HAProxy asks
   `GET /primary` / `GET /replica` on :8008. Patroni's role decision is
   authoritative; `pg_isready` against :5432 would happily route writes to a
   read-only ex-primary.
2. **`etcd3:` section, not `etcd:`.** The etcd v2 API is disabled by default
   since etcd 3.4; labs using the legacy section depend on deprecated server
   flags and misrepresent current deployments.
3. **Dynamic configuration lives in the DCS.** `bootstrap.dcs` in
   `patroni.yml` is written to etcd exactly once, at cluster bootstrap.
   All later changes go through `patronictl edit-config` — this is why the
   replication profiles are Makefile targets, not YAML file edits.
4. **`wal_log_hints: on`** enables `pg_rewind` without full data checksums;
   the lab enables checksums in `initdb` anyway, but the parameter documents
   the dependency.

## Port map (host)

| Port | Service |
|---|---|
| 5000 | writes (primary) |
| 5001 | reads (replicas) |
| 7000 | HAProxy stats |
| 8404 | HAProxy Prometheus metrics |
| 9090 | Prometheus |
| 3000 | Grafana (admin/admin, anonymous viewer enabled) |
