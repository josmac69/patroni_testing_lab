# Patroni: A Deep-Dive Technical Reference for PostgreSQL Specialists

## Glossary of Abbreviations

| Abbreviation | Meaning |
|---|---|
| **API** | Application Programming Interface |
| **BDD** | Behavior-Driven Development (testing style used by `behave`) |
| **CAS** | Compare-And-Set (atomic conditional write primitive in a DCS) |
| **CLI** | Command-Line Interface |
| **CVE** | Common Vulnerabilities and Exposures (public vulnerability identifier) |
| **DCS** | Distributed Configuration Store (etcd, Consul, ZooKeeper, Kubernetes API, Raft) |
| **DNS** | Domain Name System |
| **DoS** | Denial of Service |
| **GIL** | Global Interpreter Lock (CPython's single-thread execution lock) |
| **HA** | High Availability |
| **HTTP(S)** | Hypertext Transfer Protocol (Secure) |
| **IP** | Internet Protocol (address) |
| **K8s** | Kubernetes |
| **KV** | Key-Value (store/pair) |
| **LSN** | Log Sequence Number (position in the PostgreSQL WAL stream) |
| **MPP** | Massively Parallel Processing (Patroni's abstraction for distributed engines like Citus) |
| **OOM** | Out Of Memory (Linux OOM killer) |
| **OS** | Operating System |
| **PG** | PostgreSQL |
| **PGDATA** | PostgreSQL data directory |
| **PR** | Pull Request (GitHub) |
| **RCE** | Remote Code Execution |
| **REST** | Representational State Transfer (HTTP API style) |
| **RHEL** | Red Hat Enterprise Linux |
| **RPO / RTO** | Recovery Point Objective / Recovery Time Objective |
| **RPC** | Remote Procedure Call |
| **SSL / TLS** | Secure Sockets Layer / Transport Layer Security |
| **TCP** | Transmission Control Protocol |
| **THP** | Transparent Huge Pages |
| **TTL** | Time To Live (lease/expiry duration of a DCS key, e.g. the leader lock) |
| **VIP** | Virtual IP address |
| **VM** | Virtual Machine |
| **WAL** | Write-Ahead Log |
| **YAML** | YAML Ain't Markup Language (configuration file format) |
| **ZK** | Apache ZooKeeper |

Patroni-specific key terms (not abbreviations but used throughout): **leader lock/lease** — the DCS key whose holder may run as primary; **member key** — per-node DCS key publishing state; **failsafe mode** — availability mechanism during full DCS outages; **watchdog/softdog** — Linux kernel device that resets the host if Patroni stops sending keepalives; **quorum commit** — quorum-based synchronous replication (Patroni 4.0+).

## TL;DR

- **Patroni is a single-threaded "bot" (one agent per node) that treats a strongly-consistent DCS leader lock with a TTL lease as the single source of truth for who may run as primary**; the main `Ha.run_cycle()` state machine, an `AsyncExecutor` worker thread, and a thread-pooled REST API server together implement leader election, automatic failover, `pg_rewind`-based reattachment, synchronous/quorum replication, and permanent slot failover across PostgreSQL 9.3–18.
- The safety model rests on **"the node may run as primary only while it can renew the leader key within `ttl`"**; correctness against split-brain when Patroni itself is wedged depends on a **Linux watchdog (softdog)**, and availability during DCS outages depends on **`failsafe_mode`**. Both are optional and off by default, which is the single largest source of production foot-guns.
- Major weaknesses are architectural rather than bugs: async-replication failover loses transactions bounded by `maximum_lag_on_failover` + WAL written in the last `ttl` window; synchronous mode can still lose transactions on backend cancellation; the REST API defaults to **no authentication** (the 2020-10-14 report by Denis Bezik in issue #1734 demonstrated that "changing the PostgreSQL configuration file with PATCH requests to Patroni HTTP API allows a remote authenticated attacker to execute arbitrary OS commands"); and mis-tuned `loop_wait`/`ttl`/`retry_timeout` relative to DCS latency and clock skew is the most common operational failure class.

## Key Findings

1. **Patroni is a template/bot, not an all-in-one cluster manager.** Each node runs its own Patroni process managing exactly one local PostgreSQL. Coordination happens exclusively through the DCS; there is no Patroni-to-Patroni RPC except REST calls during the leader race and failsafe checks. This "shared-nothing except the DCS" design is why the DCS must be a real consensus store (etcd/Consul/ZooKeeper/Kubernetes-API/Raft) and why Patroni offloads all fencing-of-last-resort to a watchdog.

2. **The leader lock is a TTL lease.** `Ha.set_is_leader()` sets `self._leader_expiry = time.time() + self.dcs.ttl`; `is_leader()` is simply `self._leader_expiry > time.time()`. A node believes itself leader only for `ttl` seconds after its last successful DCS lock renewal. If `update_lock()` fails, the node demotes.

3. **Every concrete DCS maps Patroni's `ttl` onto a native primitive** — etcd v2 per-key TTL + `prevValue` CAS; etcd v3 lease + txn CAS; Consul session (`behavior=delete`) + KV acquire; ZooKeeper ephemeral znode + session timeout; Kubernetes has **no native TTL** and emulates expiry client-side from a `renewTime` annotation with `resourceVersion`/HTTP-409 optimistic concurrency.

4. **Failover vs. switchover is disambiguated by DCS state**, not by separate code paths, and candidate eligibility is gated by reachability, `nofailover`, watchdog capability, timeline (`check_timeline`), `maximum_lag_on_failover`, `failover_priority`, and (in quorum mode) quorum votes.

5. **Quorum-based synchronous replication (Patroni 4.0, available on PostgreSQL v10+)** is implemented by `QuorumStateResolver`, which maintains the invariant `quorum + numsync >= |voters ∪ sync|` so that (per the Replication modes docs) "any subset of voters that can achieve quorum includes at least one node with the latest successful commit."

6. **Permanent logical slot failover (PG 11+)** works by copying slot files from the primary over libpq and advancing them with `pg_replication_slot_advance()` on replicas in a dedicated `SlotsAdvanceThread`.

## Details

### 1. Process & concurrency model

Patroni's daemon (`patroni/__init__.py` → `daemon.py`) runs three concurrency domains:

- **Main HA-loop thread** — repeatedly calls `Ha.run_cycle()` (`patroni/ha.py`). This is the state machine. It is *single-threaded and synchronous*: one iteration per `loop_wait` seconds (woken early via `wakeup()`).
- **`AsyncExecutor` worker thread** (`patroni/async_executor.py`) — runs one long-running task at a time (bootstrap, `pg_basebackup`/clone, `pg_rewind`, promote, restart, crash recovery in single-user mode). `try_run_async(action, func)` returns `None` if scheduled or an error string if the executor is busy (`"AsyncExecutor is busy"`). `CriticalTask` provides a cancellation protocol: the main thread holds locks and calls `cancel()`; if the task already completed, `cancel()` returns `False` and `result` holds the outcome. `CancellableSubprocess` lets the main loop kill child processes (e.g. a stuck `pg_rewind`).
- **REST API server threads** (`patroni/api.py`) — `RestApiServer` is an asynchronous thread-pool HTTP server (`restapi.thread_pool_size`, default 5). `RestApiHandler` handles health checks and management requests. SQL-backed requests are effectively serialized through a single DB connection, so raising the pool size rarely helps.
- A **`SlotsAdvanceThread`** (`patroni/postgresql/slots.py`) advances logical slots on replicas so slot-advance queries don't block the main loop.

Global config `thread_pool_size` (default 5) sizes the pool used for fanning out REST calls to other members during the leader race and failsafe checks. Note the documented **Python 3.11+ / `vm.overcommit_memory=2` hazard**: starting a thread under memory pressure can hang indefinitely; releases 4.1.1+/4.0.8+ pre-start threads early and the docs recommend `MALLOC_ARENA_MAX=1` and tuning `thread_stack_size` (per Patroni 4.1.3 config docs, "Value must be aligned by 64kB. Minimal value is 64kB, default value (set by Patroni) is 512kB").

The GIL matters: because the HA loop is single-threaded Python, a long synchronous operation (e.g. slow `controldata()`, blocking DB query) can push loop time past `loop_wait`, producing `"Loop time exceeded, rescheduling immediately"` warnings and, in the worst case, delaying a lock renewal toward the `ttl` boundary.

### 2. The HA state machine (`Ha.run_cycle` / `_run_cycle`)

`run_cycle()` wraps `_run_cycle()` in exception handling (any `DCSError` → the node conservatively demotes; unexpected exceptions are logged as BUGs). `_run_cycle()`'s decision tree, in order:

1. **Config/pause bootstrapping** — `load_cluster_from_dcs()` fetches the `Cluster` object (leader, members, config, sync, failover, history, status, failsafe). It preserves `old_cluster` as the last healthy view and, if `failsafe_mode` is on and the cluster is unlocked, injects the "real" leader via `Failsafe.update_cluster()`.
2. **Postgres-not-running branch** → `recover()`. This inspects `pg_controldata` (`Database cluster state`), decides between: starting as primary after failure (if it held the lock and cluster state ∈ {in production, in crash recovery, shutting down, shut down} and no `recovery.conf`), single-user-mode crash recovery (`_handle_crash_recovery`), `pg_rewind`/reinitialize (`_handle_rewind_or_reinitialize`), or starting as a standby following `_get_node_to_follow()`. If `primary_start_timeout == 0` and the node holds the lock and a failover target exists, it disables the watchdog and `demote('immediate')`s to fail over rather than restart.
3. **Bootstrap branch** — if no `initialize` key and this node may be primary and has a `bootstrap` config section, race for the `initialize` key via `dcs.initialize(create_new=True)`, then run `initdb`/custom bootstrap/clone. `post_bootstrap()` finalizes; failure raises `PatroniFatalException('Failed to bootstrap cluster')` and renames PGDATA to `*.failed`.
4. **Unlocked cluster** → `process_unhealthy_cluster()` (docstring: *"Cluster has no leader key"*). If `is_healthiest_node()` and `acquire_lock()` succeed → promote (or become standby_leader); else `follow('...i am not the healthiest node')`.
5. **Locked cluster** → `process_healthy_cluster()`. If this node owns the lock (`has_lock()` compares `cluster.leader.name == state_handler.name`), call `update_lock()` and stay primary; process pending manual failover/switchover (demote if requested). Otherwise `follow()`.

`touch_member()` publishes this node's state to the DCS member key every cycle: `conn_url`, `api_url`, `state`, `role`, `version`, `xlog_location`, `replay_lsn`/`receive_lsn`, `replication_state`, `timeline`, `tags`, `pending_restart`, `scheduled_restart`, `pause`. It also notifies the MPP (Citus) coordinator on `after_promote`.

### 3. Leader race / healthiest-node algorithm

`_is_healthiest_node(members, check_replication_lag=True, leader=None)` (docstring: *"tries to determine whether I am healthy enough to become a new leader candidate"*) performs:

1. **Lag check** — `is_lagging(my_wal)` computes `lag = (cluster.last_leader_operation or 0) - my_wal` and fails if `lag > maximum_lag_on_failover`; logs *"My wal position exceeds maximum replication lag"*.
2. **Timeline check** — only if `check_timeline` is enabled: fail if `replica_cached_timeline(cluster.timeline) < cluster.timeline`; logs *"My timeline %s is behind last known cluster timeline %s"*.
3. **Poll peers** — `fetch_nodes_statuses(members)` fans out `fetch_node_status()` REST calls to each member's `/patroni` over the thread pool, building `_MemberStatus` objects (`reachable`, `in_recovery`, `wal_position = max(received, replayed)`, `timeline`, `watchdog_failed`, tags).
4. **Priority / WAL comparison** — (PR #2759) first, defer (`return False`) to any node within `maximum_lag_on_failover` that has a **higher `failover_priority`**; then defer to any **same-priority** node with a **higher WAL position**; else race. Nodes with `failover_priority: 0` or `nofailover` never call `acquire_lock`.

`_MemberStatus.failover_limitation()` returns the disqualifier: `'not reachable'`, `'not allowed to promote'` (nofailover), or `'not watchdog capable'`.

`is_healthiest_node()` wraps this, adds pause-mode handling (in pause a node is healthiest only if `not cluster.initialize or sysid == cluster.initialize`), synchronous/quorum gating (must be in `/sync` voters), and manual-failover handling (`manual_failover_process_no_leader()`).

**Lock acquisition** delegates to the DCS via `attempt_to_acquire_leader()` (docstring: *"The key must be created atomically. In case the key already exists it should not be overwritten"*). `update_leader()` (docstring: *"You have to use CAS … for etcd `prevValue` must be used"*) renews and, on success, calls `watchdog.keepalive()`.

### 4. DCS abstraction & concrete implementations

`patroni/dcs/__init__.py` defines `AbstractDCS(config, mpp)`. `iter_dcs_classes()`/`get_dcs()` dynamically import the module named by config (only one may be configured). Timing-critical methods must complete within `retry_timeout` or the DCS is considered inaccessible. Key DCS keys: `initialize` (cluster init race / stores sysid), `config` (dynamic config, mirrored to `patroni.dynamic.json` in PGDATA), `leader` (the lock), `status`/`optime` (leader LSN + permanent-slot positions; `/status` since 2.1.0, legacy `optime/leader` for old members), `history` (timeline history), `sync` (synchronous/quorum state), `failover` (manual request), `failsafe` (member list for failsafe), and per-member keys.

| DCS | Acquire (atomic) | Renew | Expiry primitive |
|---|---|---|---|
| **etcd v2** (`etcd.py`) | `write(..., prevExist=False)` | `write(leader, name, prevValue=self._name, ttl=self._ttl)` | native per-key TTL |
| **etcd v3** (`etcd3.py`) | `txn` compare on create_revision/value, key bound to lease | `lease_keepalive(ID)` + txn; `_do_refresh_lease` ≥1×/loop | lease TTL (`lease_grant(ttl)`) |
| **Consul** (`consul.py`) | KV `acquire=<session>` | session renew (`_do_refresh_session`) | session TTL, `behavior=delete` |
| **ZooKeeper** (`zookeeper.py`) | ephemeral znode `_create(ephemeral=True)` (NodeExists→False) | implicit (session heartbeat) | session_timeout == `ttl` |
| **Kubernetes** (`kubernetes.py`) | `patch_or_create` with `resourceVersion` | update `renewTime` annotation | **emulated**: `_leader_observed_time + ttl` |

- **etcd v2/v3**: v3 is the default modern path; a single lease TTL is refreshed at least once per HA loop. Per pgEdge's build guide, "Etcd is the default and the example most often deployed in Patroni clusters"; Crunchy Data notes its sensitivity driver — "The etcd consensus protocol requires etcd cluster members to write every request down to disk, making it very sensitive to disk write latency" — which is why a dedicated, low-latency etcd yields the lowest lock-loss false-positive rate.
- **Consul**: session `behavior=delete` deletes the leader KV when the session expires. Service registration (`register_service`, tags master/primary/replica/standby-leader) is supported.
- **ZooKeeper / Exhibitor**: `kazoo`-based; changing `ttl` requires destroying and recreating the session (`set_ttl` returns True → `restart()`). Exhibitor shares the ZK backend with dynamic ensemble discovery.
- **Kubernetes**: leader stored as annotations (`ttl`, `renewTime`, `acquireTime`, `transitions`) on an Endpoints (recommended) or ConfigMap object. Expiry is computed client-side; atomicity is `resourceVersion` optimistic concurrency (HTTP 409 → recheck & retry). This is why lock-loss false positives are more common on the K8s API (backed by etcd) than on direct etcd. Role labels (`role=primary`) are set on the pod. `bypass_api_service` and retriable-HTTP-code config exist for managed platforms.
- **Raft/pysyncobj**: a pure-Python Raft DCS (added 2.0) letting Patroni run without an external DCS. It is **deprecated** (NetApp/community materials list PySyncObj as deprecated) and generally discouraged for production.

### 5. PostgreSQL management layer (`patroni/postgresql/*`)

- **Bootstrap** (`bootstrap.py`): `initdb` (with options like `data-checksums`), custom bootstrap methods (`method:` + command, `no_params`, additional mapped args), or clone from leader/replica (`create_replica_methods`, e.g. `pg_basebackup`, WAL-E/pgBackRest wrappers). `clonefrom` tag marks preferred clone sources.
- **Start/stop/restart/reload**: Patroni fully owns `pg_ctl`; systemd auto-start must be disabled. Config changes with `context=postmaster` set `pending_restart`/`restart_pending` flags in the member key.
- **Promote/demote** (`Ha.demote(mode)`): four modes — `offline` (DCS unreachable), `graceful` (async, user-requested failover), `immediate` (unsuitable-for-primary, fast, no durability regard), `immediate-nolock` (lost the lock; fastest possible shutdown). Demotion when the lock is lost is **immediate and synchronous**.
- **`pg_rewind` integration** (`rewind.py`, class `Rewind`): triggered when timelines diverge and rewind is possible. Requires data checksums or `wal_log_hints`. Uses a dedicated `rewind_user` on PG 11+ (else superuser). **Critical correctness step**: before rewinding, Patroni ensures `pg_control` on the new primary reflects the new timeline, either by waiting for the primary to publish `checkpoint_after_promote=True` (via the member key) or by issuing a `CHECKPOINT`. After promote it issues a `CHECKPOINT` from a new thread and asynchronously verifies. It parses `pg_waldump` output to find the checkpoint-record end LSN (the message *"invalid record length … wanted 24, got 0"* encodes the next-record LSN). If `pg_rewind` lacks `--restore-target-wal`, Patroni parses stderr to fetch missing WAL via `restore_command`. `remove_data_directory_on_rewind_failure` and `remove_data_directory_on_diverged_timelines` control destructive fallback.
- **Crash recovery**: single-user-mode recovery (`_handle_crash_recovery` → `ensure_clean_shutdown`) when a former primary wasn't shut down cleanly; skipped when `backup_label` exists.
- **Recovery/standby config generation** (`config.py`): `check_recovery_conf()` does smart comparison of desired vs. actual `primary_conninfo`; handles the PG 12 removal of `recovery.conf` transparently (the `recovery_conf` config section still works).
- **`pg_controldata`** parsing drives recovery decisions; `pg_control_checkpoint()` used on 9.6+ for timeline.

### 6. Failover, switchover, candidate selection

`_get_failover_action_name()` classifies the `/failover` DCS key: empty → `failover`; has candidate but no leader → `manual failover`; has leader → `switchover`. Eligibility checks (`is_failover_possible`, `_MemberStatus.failover_limitation`): reachable, not `nofailover`, watchdog-capable, within `maximum_lag_on_failover`, timeline ≥ cluster timeline if `check_timeline`, and — in quorum mode — enough quorum votes. Manual **failover in a cluster without a leader** relaxes checks (may promote a lagging/behind-timeline/non-sync node). REST: `POST /failover`, `POST /switchover`, `DELETE /switchover` (cancel scheduled). Scheduled operations require timezone-aware future timestamps; `poll_failover_result()` waits up to `max(10, loop_wait*2)`s.

`before_stop` (synchronous, blocking shutdown) and `pre_promote` (fencing script; non-zero exit aborts promotion and releases the leader key) hooks exist.

### 7. Synchronous & quorum replication (`ha.py`, `quorum.py`, `postgresql/sync.py`)

- **`synchronous_mode: on`** — `_process_multisync_replication()` maintains `synchronous_standby_names` and the `/sync` DCS key with strict ordering: **add to `postgresql.conf` first, then DCS; remove from DCS first, then conf** — so only guaranteed-synchronous standbys are ever promotable. `synchronous_node_count` (default 1) sets how many sync standbys.
- **`synchronous_mode: quorum`** (Patroni 4.0, PostgreSQL v10+) — `_process_quorum_replication()` drives `QuorumStateResolver(leader, quorum, voters, numsync, sync, numsync_confirmed, active, sync_wanted, leader_wanted)`, which yields ordered `Transition(type, leader, num, names)` steps for `sync`/`quorum` keys maintaining `quorum + numsync >= |voters ∪ sync|`. Increasing `synchronous_node_count` raises `numsync` (synchronous_standby_names) first then lowers `quorum`; decreasing does the reverse. Failover candidate is chosen by latest received transaction; only nodes not behind ≥1 of the quorum set can promote losslessly.
- **`synchronous_mode_strict`** — never disables sync even with no available standby (`synchronous_standby_names='*'`), blocking writes to guarantee durability.
- **`maximum_lag_on_syncnode`** (default -1 = never swap) governs swapping an unhealthy sync standby for a healthy async one.
- **Known durability caveat** (documented): even in strict mode, a backend cancelled while awaiting sync ack makes its changes visible to other backends before replication — those can be lost on promotion.

`_disable_sync` counter (protected by `_member_state_lock`) lets a node temporarily request removal from sync (via `nosync`/`sync_priority: 0` effective tags) with a documented tiny race window (holds commits at most one cycle).

### 8. REST API (`patroni/api.py`)

Health checks (GET, also HEAD/OPTIONS for header-only): `/`, `/primary` (=leader running as primary), `/standby-leader`, `/leader` (holds lock regardless of primary/standby-leader), `/replica` (running, role replica, no `noloadbalance`), `/replica?lag=<max>`, `/read-only` (replicas + primary), `/read-only-sync`, `/read-only-quorum`, `/sync`, `/async`/`/asynchronous` (+`?lag=`), `/health` (Postgres up), `/liveness` (heartbeat loop alive; 503 if last run > `ttl` on primary or `2*ttl` on replica), `/readiness`, `/metrics` (Prometheus), `/cluster`, `/config`, `/patroni`. Management (POST/unsafe): `/switchover`, `/failover`, `/restart` (+DELETE), `/reload`, `/reinitialize` (replicas only; `{"force":true}` to override a recovery loop), `/config` (PATCH), `/citus`/`/mpp`, `/failsafe`. HAProxy uses `option httpchk` against `/primary` and `/replica?lag=` — expected `[WARNING]` for the non-matching role on each node is harmless.

**Security**: TLS via `restapi.certfile`/`keyfile`; client-cert auth via `verify_client` (`none`/`optional`/`required` — optional means only unsafe calls need certs); basic-auth via `restapi.authentication`. `allowlist`/`allowlist_include_members` restrict unsafe-endpoint IPs. **By default the API is unauthenticated**; the report filed by Denis Bezik on 2020-10-14 in issue #1734 ("Authenticated RCE via Patroni HTTP REST API", blog illegalbytes.com/2020-10-14/patroni-remote-code-execution/) showed that "changing the PostgreSQL configuration file with PATCH requests to Patroni HTTP API allows a remote authenticated attacker to execute arbitrary OS commands." Historical CVEs relate mainly to bundled deps (e.g. `certifi` CVE-2024-39689). A separate hardening fix addressed a TLS-handshake DoS where an idle client blocked an API thread.

### 9. patronictl (`patroni/ctl.py`)

Click-based CLI reading the same YAML/DCS. Commands: `list`, `topology` (ASCII cascading tree), `history`, `show-config`, `edit-config` (ydiff-based diff; validates), `switchover`, `failover` (excludes current leader as candidate since 4.x), `restart`, `reload`, `reinit`, `flush` (cancel scheduled restart/switchover), `pause`/`resume`, `query`, `dsn`, `remove` (deletes DCS metadata only — dangerous), `scaffold`, `configure`, `version`. It interacts with the DCS directly (reads cluster state, writes `/failover`, `/config`) and via REST (restart/reinit/reload/failover execution). `--group` supports Citus. `patronictl failover` dropped `--leader` (deprecated since 3.2.0, removed in 4.0).

### 10. Watchdog (`patroni/watchdog/*`)

Linux `/dev/watchdog` (softdog) support only. Patroni pings the watchdog immediately after each successful leader-key renewal (`watchdog.keepalive()` inside `update_lock()`). It activates the watchdog **before** promotion; if activation fails and mode is `required`, the node refuses to become leader and `_MemberStatus.watchdog_failed` disqualifies it from the race. Disabled on demotion and in pause. Per the Watchdog docs: "By default Patroni will set up the watchdog to expire 5 seconds before TTL expires. With the default setup of loop_wait=10 and ttl=30 this gives HA loop at least 15 seconds (ttl - safety_margin - loop_wait) to complete before the system gets forcefully reset." The same docs state that when the DCS is unavailable "Patroni and PostgreSQL will have at least 5 seconds (ttl - safety_margin - loop_wait - retry_timeout) to come to a state where all client connections are terminated." For an absolute guarantee, "set up the watchdog to expire after half of TTL by setting safety_margin to -1 to set watchdog timeout to ttl // 2. If you need this guarantee you probably should increase ttl and/or reduce loop_wait and retry_timeout." This is the *only* mechanism that reliably prevents split-brain when Patroni is crashed/hung/paused-by-hypervisor while Postgres keeps accepting writes.

### 11. Callbacks & tags

Callbacks (`postgresql.callbacks`, passed action/role/scope): `on_start`, `on_stop`, `on_restart`, `on_role_change`, `on_reload`. Plus `pre_promote` (fencing) and `before_stop` (synchronous pre-shutdown). Since 4.0 callbacks receive `role=primary` (not `master`).

Tags (`tags:` per node): `nofailover` (never promote; takes precedence over contradictory `failover_priority`), `noloadbalance` (fail `/replica` health check; excluded from Citus `pg_dist_node` secondaries), `clonefrom` (preferred clone source), `nosync` (never a sync standby), `nostream` (don't stream from primary — use archive only), `replicatefrom` (cascade from a named member), `failover_priority` (integer; higher wins; 0 = never). `{nofailover: false, failover_priority: 0}` — `nofailover` precedence was clarified so priority 0 still participates only when nofailover is false (release-note fix).

### 12. Standby clusters, permanent slots, failsafe

- **Standby cluster** (`standby_cluster` config): the whole cluster follows a remote primary via a `standby_leader`; cascading replication to local replicas. Decoupled from the source, it detects timeline switches by watching for new history files and triggers rewind/reinitialize. Postgres does not support cascading synchronous replication, so sync mode is ignored to avoid breaking standby switchover.
- **Permanent slots** (`slots:` config, `use_slots`): physical and logical. On PG 11+ physical member slots are maintained on *all* nodes that could become leader (via `pg_replication_slot_advance`), so WAL is retained for potential new leaders; absent-member slots are dropped after `member_slots_ttl` (per Patroni 4.1.3 docs, "retention time of physical replication slots for replicas when they are shut down. Default value: 30min… The feature works only starting from PostgreSQL 11", and per the FAQ available since Patroni 4.0.0). Logical slots are copied primary→replica by reading slot files over libpq (rewind/superuser creds) and advanced every `loop_wait`; the `SlotsAdvanceThread` avoids blocking the loop. Logical slot failover is PG 11+ only (unsafe on ≤9.6, missing functions on 10). Post-failover a consumer may see some messages twice (track `confirmed_flush_lsn`). `should_enforce_hot_standby_feedback` auto-enables `hot_standby_feedback` when logical slots (or cascading downstream) exist. Slots matching member names persist; `ignore_slots` excludes externally-managed slots. Slot advance never passes `replay_lsn` on replicas.
- **`failsafe_mode`** (`patroni/ha.py`, class `Failsafe`): enabled only via DCS `/config`. When the leader can't update the DCS lock for reasons other than version/value mismatch, it may keep running as primary **iff it can reach *all* known members** (from the `/failsafe` key) via `POST /failsafe`. Replicas receiving the failsafe ping treat it as proof the primary is alive and won't start a leader race even if the lock expired. A member may win the race only if present in `/failsafe`. This trades the strict "must renew DCS lock" rule for availability during whole-DCS outages; the "check ALL members" rule prevents a minority-partition primary from surviving. State is TTL-bounded (`_last_update + dcs.ttl`).

### 13. Citus / MPP support (Patroni 3.0+, `postgresql/mpp/citus.py`)

`citus:` config (`group`, `database`). Coordinator (group 0) auto-discovers worker primaries and maintains `pg_dist_node` via `citus_add_node`/`citus_update_node`; secondaries with `role=replica`/`state=running`/no `noloadbalance` are registered. Worker switchover runs a transaction (`citus_update_node`) held open across demote/promote so the coordinator's metadata stays consistent (`PgDistGroup`/`PgDistNode`). `synchronous_mode` defaults to `quorum` for Citus. `patronictl` gains `--group`; `notify_mpp_coordinator` sends `before_demote`/`after_promote` events over REST.

### 14. Configuration system

Precedence (highest first): **environment variables (`PATRONI_*`)** → **local YAML** → **dynamic config in DCS** → **built-in defaults** (`Config.__DEFAULT_CONFIG`). `_build_effective_configuration()` merges them. Dynamic config (`bootstrap.dcs` seeds it once at init; thereafter only `patronictl edit-config`/REST changes take effect) is cached to `patroni.dynamic.json` (atomic temp-file+rename) for DCS-outage recovery; only the leader restores from the on-disk dump if DCS is empty/invalid. Some parameters (`max_connections`, `max_worker_processes`, `max_locks_per_transaction`, `max_prepared_transactions`, `wal_level`) must be equal cluster-wide and are DCS-only. `patroni --validate-config` and the config generator (`--generate-config`, `--generate-sample-config`) exist.

### 15. Timing model — `loop_wait`, `ttl`, `retry_timeout`

Defaults/minimums: `loop_wait` 10 (min 1), `ttl` 30 (min 20), `retry_timeout` 10 (min 3). Worst-case failover time for a primary crash ≈ `loop_wait + primary_start_timeout + loop_wait` (or just `loop_wait` if `primary_start_timeout=0`). Async data-loss bound ≈ `maximum_lag_on_failover` bytes + WAL written in the last `ttl` (avg `loop_wait/2`). **Safe-tuning rule**: `ttl > loop_wait + 2*retry_timeout` (so a DCS blip shorter than `retry_timeout` doesn't demote the leader, and the loop plus retries fit inside the lease). With watchdog, HA loop budget = `ttl - safety_margin - loop_wait`; DCS-outage grace before all connections must terminate = `ttl - safety_margin - loop_wait - retry_timeout`. Lowering `ttl` speeds failover but raises false-positive-demotion risk under DCS/disk/clock jitter.

### 16. Release history

- **Governor → Patroni**: forked from Compose Governor 2015-07; Patroni 1.0 2016-07.
- **1.4** K8s DCS; **1.5** cascading replication, Consul service registration, Windows (experimental); later psycopg2 made optional.
- **2.0 (2020-09)**: dynamic-config maturity, **etcd v3 API**, **pure Raft (pysyncobj)**, multiple sync standbys, major `pg_rewind` improvements, optional `pre_promote` fencing, PG 13 support.
- **2.1 (2021-07)**: logical-slot failover.
- **3.0**: **Citus** integration; **`failsafe_mode`**; first step renaming master→primary (must run ≥3.0.0 before upgrading further).
- **3.2**: deprecated `bootstrap.users` and `patronictl failover --leader`.
- **4.0**: **quorum-based synchronous replication** (`QuorumStateResolver`); Citus secondary registration; `member_slots_ttl`; configurable log-file permissions; completed master→primary removal (callbacks now `role=primary`; upgrade requires ≥3.1.0). Current line 4.1.x (docs reference 4.1.4). PG 9.3–18 supported.

### 17. Packaging, dependencies, tests

Extras: `pip install patroni[etcd|etcd3|consul|zookeeper|exhibitor|kubernetes|raft|aws|systemd|all|psycopg3|psycopg2|psycopg2-binary]`. `psycopg[binary]>=3.0.0` supported since 2.1.2; `psycopg2>=2.5.4` still works (cannot express "either" in one dep). Other deps: `click` (CLI), `ydiff` (edit-config diffs; pinned compat with 1.4.2), `prettytable` (≥3.12 compat), `PyYAML`, `urllib3`, `py-consul` (replacing unmaintained `python-consul`), `kazoo` (ZK, ≥2.6 for SSL), `pysyncobj` (Raft), `kubernetes`. Testing: **`pytest`** unit tests (`tests/`, e.g. `test_ha.py`, `test_api.py`, `test_slots.py`) with heavy mocking of DCS/Postgres; **`behave`** BDD acceptance tests (`features/*.feature` + `features/steps/*.py` + `environment.py`) run against real Postgres (PG 11–16 Docker images) covering watchdog, ignored_slots, cascading replication, basic replication, etc. `tox.ini` orchestrates test/type(pyright)/behave/docs environments across Python versions and OSes.

## Recommendations

1. **Always deploy the watchdog in production.** Without softdog, split-brain protection is not guaranteed if Patroni crashes, is OOM-killed, is paused by the hypervisor, or Postgres shuts down too slowly. Set `chown postgres /dev/watchdog`, `modprobe softdog`, and `watchdog.mode: required` on nodes that may lead. If you need an absolute guarantee, set `safety_margin: -1` (watchdog = `ttl//2`) and correspondingly raise `ttl`/lower `loop_wait`.
2. **Tune timing to your DCS latency and clock stability.** Keep `ttl > loop_wait + 2*retry_timeout`. On Kubernetes-API-as-DCS or high-latency/etcd-on-shared-disk deployments, *increase* `ttl`/`retry_timeout` to avoid spurious demotions (the K8s API path has materially higher lock-loss false positives than direct etcd). Benchmark: if you see recurring `"Loop time exceeded"` or unexpected `Demoting self (immediate-nolock)`, raise `retry_timeout` first, then `ttl`. Prefer dedicated etcd for the DCS.
3. **Choose the durability posture explicitly.** For zero-data-loss requirements use `synchronous_mode: on` (or `quorum` for lower tail latency with ≥3 nodes) plus `synchronous_mode_strict` — and accept write unavailability when no sync standby is reachable. For availability-first, use async with a small `maximum_lag_on_failover` and document the loss bound. Never rely on sync mode alone to guarantee zero loss (backend-cancellation caveat).
4. **Lock down the REST API.** Enable basic-auth (`restapi.authentication`) *and* TLS with `verify_client: optional` (or `required`), and set `allowlist`/`allowlist_include_members`. Treat the API as a config-write/RCE surface, not just health checks. Never expose port 8008 cluster-wide on Kubernetes without auth.
5. **For `pg_rewind`, initialize with `--data-checksums` (or `wal_log_hints`)** and provision a dedicated `rewind_user` on PG 11+. Be aware of the historical "rewind before promotion checkpoint" data-loss class (issue #2073); keep Patroni current, since fixes tie rewind to `checkpoint_after_promote`.
6. **Enable `failsafe_mode`** for clusters where a full DCS outage would otherwise demote a healthy primary — but only after confirming *all* members run a recent, uniform Patroni version, since a member absent from `/failsafe` cannot win the race.
7. **Use `pause` for maintenance**, not `nofailover`, when you want to stop automatic failover but keep manual switchover; understand that pause also disables auto-restart of failed Postgres and permits transient multiple primaries (Patroni only warns on "parallel primaries").
8. **Thresholds that should change your config**: sustained loop-time > `loop_wait` → reduce synchronous work / raise `loop_wait`; frequent sync-standby swaps → raise `maximum_lag_on_syncnode`; WAL bloat on replicas from user slots → move consumers to the leader or define permanent slots; Python 3.11+ with `vm.overcommit_memory=2` → set `MALLOC_ARENA_MAX=1` and upgrade to ≥4.1.1/4.0.8.

## Caveats

- **Single-threaded HA loop / GIL**: any blocking operation in the main thread delays lock renewal; long `pg_controldata`, slow DNS, or a stuck child can push toward the `ttl` boundary. This is by design (simplicity/determinism) but demands conservative timing.
- **Async failover always risks transaction loss** bounded by `maximum_lag_on_failover` + last-`ttl` WAL; the lost transactions live on a forked timeline and are recoverable only manually (or erased by `pg_rewind`).
- **Synchronous mode is not an absolute guarantee**: backend cancellation during sync wait, or simultaneous loss of primary + sync standby, can still lose/expose transactions.
- **Kubernetes DCS has no true lease**; expiry is client-time-based, making it more sensitive to clock skew and API latency than etcd/Consul/ZK.
- **Slow Postgres shutdown vs. lock release**: Patroni may release the leader lock once `pg_control` shows "shut down" and a replica has the WAL, *before* Postgres fully terminates — external VIP managers reacting to lock release can strand TCP connections (configure TCP keepalives; see discussion #3235).
- **Clock skew / VM snapshots** can trigger unexpected demotion (e.g. etcd leader election during a VM snapshot producing `not a primary lessor`, issue #3407).
- **Cascading replication + slots** has produced recurring bugs (e.g. switchover/failover failures with `replicatefrom` + slots, issue #2137).
- **Raft/pysyncobj DCS is deprecated**; don't build new production clusters on it.
- Version-specific behavior differences (PG 9.x recovery.conf vs. 12+ signal files; pg_rewind/pg_waldump message-format change in v16) are handled in code but mean **Patroni version and PG version must be considered together**; mixed-Patroni-version clusters during upgrades can behave unexpectedly if the primary fails mid-upgrade (upgrade to 4.x requires ≥3.1.0 first).
- Several claims here (exact line numbers, some DCS method bodies) were confirmed via API docs/changelogs/tracebacks rather than full source reads; treat method *names* and *semantics* as high-confidence and line numbers as approximate/version-dependent.
