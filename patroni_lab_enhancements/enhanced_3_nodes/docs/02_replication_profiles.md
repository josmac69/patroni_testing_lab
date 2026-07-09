# Replication profiles

The lab ships three replication profiles and two timer profiles, all applied
at runtime through the DCS (`make profile-*`). Boot once, switch profiles
live, re-run the same failure — this is the core teaching loop.

## Profiles

### `profile-async` (default)
`synchronous_mode: false`. Commits return after local WAL flush. Highest
throughput, lowest latency, and **non-zero RPO on a hard leader crash**:
transactions acknowledged to the client but not yet streamed to any replica
are lost when a replica is promoted. `maximum_lag_on_failover` (1 MB default)
only bounds *how far behind* a promotion candidate may be — it does not
prevent loss.

### `profile-quorum` (Patroni ≥ 4.0)
`synchronous_mode: quorum`, `synchronous_node_count: 1`. Patroni manages
`synchronous_standby_names = 'ANY 1 (patroni2, patroni3)'` and maintains the
voter set in the DCS `/sync` key, guaranteeing that any node able to win the
leader race has acknowledged every visible commit. Expected results:

* RPO = 0 on leader crash (verify with the harness)
* per-commit latency increases by roughly one network round trip
* if **both** replicas fail, writes block (quorum unsatisfiable) — show this

Verify on the primary:

    psql -h localhost -p 5000 -U postgres -c 'show synchronous_standby_names'

### `profile-strict`
`synchronous_mode: true` + `synchronous_mode_strict: true`. Classic
1-sync-standby mode; strict means Patroni never falls back to async when no
sync standby is available — writes block instead. Durability caveat worth
stating precisely: even strict mode cannot protect a transaction whose
backend is cancelled while waiting for the standby acknowledgment; the
commit record is already in local WAL. This is PostgreSQL semantics, not a
Patroni defect (see the Jepsen discussion linked in the top-level README).

## Timer profiles

| Parameter | default | aggressive | effect |
|---|---|---|---|
| ttl | 30 | 20 | leader key lifetime; upper bound for detection |
| loop_wait | 10 | 5 | HA loop period |
| retry_timeout | 10 | 5 | DCS/PostgreSQL operation retries |

Rules Patroni enforces: `ttl >= loop_wait + retry_timeout * 2` (it will
correct violations and log a warning). Aggressive timers shorten failover
but make the cluster more sensitive to DCS latency hiccups — with a loaded
etcd, too-tight timers cause spurious demotions. Demonstrate by combining
`profile-aggressive-timers` with the chaos latency scripts.

## Suggested measured experiment matrix

Run `make measure-rpo-rto` during each cell; record RTO/RPO:

|  | crash (`scenario-failover`) | switchover |
|---|---|---|
| async | RPO likely > 0, RTO ~ttl+ε | RPO 0, RTO seconds |
| quorum | RPO 0, RTO similar | RPO 0 |
| strict | RPO 0; writes block if last sync standby dies | RPO 0 |
