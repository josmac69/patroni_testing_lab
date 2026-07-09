# Measuring RPO and RTO

"Failover works" is not an engineering statement. The harness
(`client/rpo_rto_harness.py`) produces numbers:

* **RTO** — wall-clock gap between the last acknowledged commit before the
  outage and the first after it, as seen by the application through HAProxy.
  This includes every layer: Patroni detection, promotion, HAProxy health
  check convergence, client reconnect.
* **RPO** — count of transactions that were *acknowledged as committed* to
  the client but are absent from the table after recovery. Only
  acknowledged-and-lost counts; in-flight failures are not data loss.

## Protocol

    terminal 1:  make measure-rpo-rto        # runs 120 s at ~20 tx/s
    terminal 2:  make scenario-failover      # (or any other scenario)

The harness prints per-outage RTO live and a final RPO verdict; exit code 1
on any lost acknowledged commit, which makes it directly usable in CI.

## Results template

| profile | timers | scenario | RTO (s) | RPO (lost tx) |
|---|---|---|---|---|
| async | 30/10/10 | crash | | |
| async | 20/5/5 | crash | | |
| quorum | 30/10/10 | crash | | |
| quorum | 30/10/10 | switchover | | |
| strict | 30/10/10 | crash | | |

## Interpretation guidance

* Async crash losses scale with write rate × replication lag at the moment
  of the kill; run at higher `--interval 0.01` rates to make losses larger
  and more reliably reproducible for demos.
* If quorum mode ever shows RPO > 0, that is a finding worth investigating,
  not noise — capture logs and the DCS `/sync` history.
* RTO decomposition: compare the harness RTO with the REST-level detection
  time printed by `scenario_failover.sh`; the difference is the routing
  layer's share (HAProxy check cadence + client reconnect), often a third of
  the total. This motivates the routing_variants lab.
