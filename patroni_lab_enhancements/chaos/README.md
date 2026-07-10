# Chaos engineering for the Patroni lab

`docker network disconnect` is binary: connected or not. Real networks fail
in gradients — latency spikes, packet loss, asymmetry, brief flaps. This
module adds graduated fault injection against the running
`enhanced_3_nodes` stack using **Pumba** (netem-based, no changes to the
stack required) plus a documented **Toxiproxy** variant for surgical
per-connection faults.

All scripts operate on the live containers of the enhanced lab; start it
first (`cd ../enhanced_3_nodes && make up`).

## Why this matters for Patroni specifically

Patroni's correctness depends on *relative timing*: `ttl`, `loop_wait`,
`retry_timeout` versus real network behaviour. The interesting failures are
not "leader dead" but:

* **DCS slow, not down.** etcd answers, but at 900 ms. With
  `retry_timeout: 10` nothing happens; with aggressive timers (5 s) a busy
  loop iteration can miss the key refresh — spurious demotion. Reproduce it,
  then defend the default timers with data.
* **Asymmetric partition.** Leader can reach etcd, replicas cannot (or vice
  versa). The failure domain of the control plane and data plane diverge.
* **Packet loss on the replication link.** Streaming replication degrades,
  lag grows, `maximum_lag_on_failover` starts excluding candidates — a crash
  during this window changes the failover outcome.
* **The failsafe 2-second edge.** failsafe_mode polls members with a
  hardcoded 2 s timeout; inject 2.5 s latency between leader and a member
  during a DCS outage and watch the safety net fail to engage.

## Scripts (`pumba/`)

| Script | Fault |
|---|---|
| `netem_delay.sh <container> <ms> <duration>` | add latency on egress |
| `netem_loss.sh <container> <pct> <duration>` | packet loss |
| `pause_process.sh <container> <duration>` | SIGSTOP the whole container (freeze, distinct from kill) |
| `flap_network.sh <container> <cycles>` | repeated short disconnect/reconnect |

Pumba runs as a transient container with access to the Docker socket; the
scripts pull `gaiaadm/pumba` on first use. netem faults require the target
container image to tolerate `tc` injection via Pumba's helper (`--tc-image
ghcr.io/alexei-led/pumba-alpine-nettools` is used by the scripts, no changes
to lab images needed).

## Experiment recipes

1. **Slow DCS, default vs aggressive timers.**
   ```bash
   # Add 800ms delay to all three etcd nodes for 120 seconds:
   ./pumba/netem_delay.sh etcd1 800 120s
   ./pumba/netem_delay.sh etcd2 800 120s
   ./pumba/netem_delay.sh etcd3 800 120s
   ```
   *Expected Outcome:* Stable under default timers. If you switch to aggressive timers (`make -C ../enhanced_3_nodes profile-aggressive-timers`), repeating this will trigger leader-key refresh failures and spurious demotion.
   *Verify:* Check cluster status via `make -C ../enhanced_3_nodes status`.

2. **Replication degradation before a crash.**
   ```bash
   # Inject 15% packet loss on patroni2 for 120 seconds:
   ./pumba/netem_loss.sh patroni2 15 120s
   ```
   *Expected Outcome:* Streaming replication lag grows.
   *Verify:* Watch the lag increase on the Grafana dashboard or check:
   ```bash
   docker compose -f ../enhanced_3_nodes/docker-compose.yml exec patroni1 patronictl -c /tmp/patroni.yml list
   ```
   While lag is high, trigger a failover:
   ```bash
   make -C ../enhanced_3_nodes scenario-failover
   ```
   Observe candidate selection honoring `maximum_lag_on_failover`.

3. **Freeze, not kill.**
   ```bash
   # Freeze the leader (e.g. patroni1) for 60 seconds:
   ./pumba/pause_process.sh patroni1 60s
   ```
   *Expected Outcome:* The leader stops renewing the DCS key but is not dead. The remaining nodes promote a new leader. When the ex-leader unfreezes, the watchdog triggers to prevent split-brain.
   *Verify:* View logs using `make -C ../enhanced_3_nodes logs`.

## Toxiproxy variant (`toxiproxy.md`)

Pumba injects faults per container. Toxiproxy injects them per *connection*,
which is what you need to break only Patroni→etcd while leaving
replica→primary streaming intact. See `toxiproxy.md` for the compose
extension and proxy definitions.
