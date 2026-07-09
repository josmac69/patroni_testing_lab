# Patroni Testing Lab — Enhancement Package

Drop-in extension of `patroni_testing_lab`, built along the roadmap from the
repository analysis. Design goals: a **learning lab** first — every scenario
carries an expected timeline and the teaching point it exists for — and
every claim about failover behaviour is backed by a measurement, not an
assertion.

## Contents

| Directory | What it adds |
|---|---|
| `enhanced_3_nodes/` | The flagship lab: 3× Patroni/PostgreSQL, **3-node etcd quorum**, HAProxy, Prometheus + Grafana, continuous write client, RPO/RTO harness, runtime-switchable replication profiles (async / quorum / strict), failsafe_mode and watchdog scenarios |
| `chaos/` | Graduated fault injection with Pumba (latency, loss, freeze, flapping) and a Toxiproxy guide for per-connection faults, incl. the failsafe 2 s timeout edge case |
| `backup_pgbackrest/` | pgBackRest repository, `create_replica_methods`, bootstrap-from-backup, PITR runbook |
| `upgrade_pg_major/` | `pg_upgrade --link` runbook under Patroni with the DCS-wipe and standby-rebuild steps scripted |
| `routing_variants/` | PgBouncer variant plus measured comparison notes for libpq multi-host and vip-manager |
| `ci/` | Example GitHub Actions workflow: the lab boots, fails over and gates on RPO = 0 in CI |

## Relationship to the existing labs

* `classic_3_nodes/` remains the minimal introduction. `enhanced_3_nodes/`
  is its production-grade sibling; the most important structural difference
  is the real 3-node etcd quorum, which is what makes the DCS scenarios
  honest.
* `cluster_with_standby_cluster/` is unchanged and complementary; the
  pgBackRest and upgrade modules apply to it equally.

## Suggested learning path

1. `enhanced_3_nodes` — architecture, profiles, scenarios 01–07 in order,
   with the RPO/RTO harness running (docs 01→06).
2. `chaos` — repeat scenarios under degraded (not dead) conditions.
3. `backup_pgbackrest` — what replication does not protect against.
4. `upgrade_pg_major` — the maintenance operation everyone rehearses too late.
5. `routing_variants` — decompose the RTO into Patroni's share and the
   routing layer's share.

## Version notes

* Patroni pinned to 4.1.4; PostgreSQL major selectable via `.env`
  (`PG_MAJOR`, 14–18). Quorum commit requires Patroni ≥ 4.0; failsafe_mode
  ≥ 3.0.
* The `etcd3:` (v3 API) section is used throughout; etcd disabled the v2
  API by default in 3.4.

## Known limitations / verification status

This package was authored offline and has **not** been booted end to end.
Before first use, expect a verification pass (a Claude Code session in the
repository is well suited): image tags may need bumping, the Grafana lag
panel query may need adjustment to the exact metric names your pinned
Patroni version emits, and scenario sleep timings may need tuning on slow
hosts. The CI workflow in `ci/` is the systematic way to keep it verified.

## Durability further reading

The strict-mode caveat cited in `enhanced_3_nodes/docs/02` (a cancelled
backend can surface an acknowledged-but-unreplicated commit) traces to
PostgreSQL replication semantics; see Bin Wang's Jepsen-style test of
Patroni 4.0.3 and the related Patroni issue discussions for the precise
mechanism. Reproducing it live is an excellent advanced-training exercise
on top of the chaos module.
