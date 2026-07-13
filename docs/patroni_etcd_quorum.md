# Patroni and etcd Quorum

Patroni delegates all cluster quorum and split-brain prevention to etcd (referred to as the Distributed Configuration Store, or DCS). Patroni agents run on every PostgreSQL node, constantly trying to create or renew a time-limited "leader key" (lease) inside etcd. Whichever Patroni agent holds that key becomes the PostgreSQL Primary. [1, 2, 3, 4]
The resilience of your database cluster depends entirely on how many etcd nodes you deploy.
------------------------------
## Scenario 1: A 1-Node etcd Topology
Running a single etcd node means your consensus layer has no high availability. [5, 6]

* The Quorum Rule: For 1 etcd node, the required quorum is 1 node. [7, 8, 9]
* How it handles quorum: As long as that single etcd process is up and reachable by the Patroni agents, everything functions smoothly. [5]
* When the single etcd node crashes:
* The etcd consensus layer is completely dead.
   * Because the active Patroni Primary cannot reach etcd to renew its leader lease, its lease expires.
   * To protect against data corruption, the Patroni agent demotes the PostgreSQL Primary to a Read-Only Replica.
   * Result: Your entire database cluster gets stuck in a read-only state until the single etcd node is manually recovered. [1, 5, 10, 11, 12]

------------------------------
## Scenario 2: A 3-Node etcd Topology
This is the standard production blueprint, giving the cluster a self-healing consensus layer. [13, 14, 15]

* The Quorum Rule: For 3 etcd nodes, the required quorum is a strict majority of 2 nodes. [8, 13]
* If 1 etcd node crashes:
* The remaining 2 etcd nodes can still communicate, satisfying the quorum rule (2 ≥ 2).
   * The etcd cluster holds an internal Raft election, picks a new etcd leader, and continues running normally.
   * The Patroni agents seamlessly pivot their API requests to the surviving etcd nodes. PostgreSQL suffers zero downtime or disruption. [2, 13, 16, 17, 18]
* If a Network Partition Occurs (Split-Brain Prevention):
* Imagine a network cut splits your datacenter: Side A has 2 etcd nodes and the Postgres Primary. Side B has 1 etcd node and a Postgres Replica.
   * Side A holds the majority quorum (2/3). The Patroni Primary on Side A successfully renews its lease and keeps processing reads and writes.
   * Side B has isolated itself with only 1 etcd node. Because it cannot reach a quorum (1 is less than the required 2), this etcd node freezes and refuses write commands. The Patroni agent on Side B cannot steal the leader key, preventing a catastrophic split-brain where two Postgres nodes think they are both the primary. [13, 14, 19, 20, 21]

------------------------------
## Architectural Summary

| Feature | 1-Node etcd | 3-Node etcd |
|---|---|---|
| Required etcd Quorum | 1 node | 2 nodes |
| Fault Tolerance | 0 nodes (Single point of failure) | 1 node can completely fail |
| If etcd Quorum is Lost | Postgres instantly becomes Read-Only | Postgres instantly becomes Read-Only |
| Use Case | Local testing/Development only | Production environments |

## The "Watchdog" Fail-Safe
If Patroni encounters an operating system freeze or sudden network blockage where it can't talk to etcd, it relies on a Linux kernel feature called /dev/watchdog. If Patroni fails to check in with etcd and the local OS watchdog before the lease window expires, the watchdog hard-resets or panics the operating system (fencing). This acts as an absolute physical guarantee that a cut-off primary cannot accept rogue writes. [1, 11, 22]

[1] [https://docs.percona.com](https://docs.percona.com/postgresql/18/solutions/patroni-info.html)
[2] [https://www.pgedge.com](https://www.pgedge.com/blog/how-patroni-brings-high-availability-to-postgres)
[3] [https://www.cybertec-postgresql.com](https://www.cybertec-postgresql.com/en/introduction-and-how-to-etcd-clusters-for-patroni/)
[4] [https://www.crunchydata.com](https://www.crunchydata.com/blog/patroni-etcd-in-high-availability-environments)
[5] [https://gse.kz](https://gse.kz/en/blog/postgresql-high-availability-patroni-pacemaker-3-nodes)
[6] [https://medium.com](https://medium.com/@preetamdalbanjan6363/postgresql-patroni-cascade-cluster-replication-9ca95750885c)
[7] [https://www.postgresql.eu](https://www.postgresql.eu/events/pgconfeu2025/sessions/session/7018/slides/771/patroni_talk_pgconf2025.pdf)
[8] [https://www.postgresql.eu](https://www.postgresql.eu/events/pgconfeu2025/sessions/session/7018/slides/771/patroni_talk_pgconf2025.pdf)
[9] [https://www.ibm.com](https://www.ibm.com/docs/en/rsct/3.2?topic=domain-quorum)
[10] [https://forums.percona.com](https://forums.percona.com/t/etcd-patroni-cluster-what-if-etcd-stops/27725)
[11] [https://xylentis.com](https://xylentis.com/blog/building-a-high-availability-postgresql-cluster-automated-failover-with-patroni-and-etcd-on-vps)
[12] [https://ongres.com](https://ongres.com/blog/improving-your-postgres-high-availability/)
[13] [https://brkylmzco.medium.com](https://brkylmzco.medium.com/postgresql-high-availability-in-production-patroni-etcd-haproxy-keepalived-a-dba-best-eb0a973930d0)
[14] [https://xylentis.com](https://xylentis.com/blog/building-a-high-availability-postgresql-cluster-automated-failover-with-patroni-and-etcd-on-vps)
[15] [https://www.enterprisedb.com](https://www.enterprisedb.com/docs/supported-open-source/patroni/)
[16] [https://www.pgedge.com](https://www.pgedge.com/blog/using-patroni-to-build-a-highly-available-postgres-clusterpart-1-etcd)
[17] [https://github.com](https://github.com/patroni/patroni/issues/2180)
[18] [https://medium.com](https://medium.com/@vaibhavverma016/part-1-installing-etcd-on-ec2-for-a-robust-ha-dr-patroni-cluster-95422c5b056e)
[19] [https://github.com](https://github.com/patroni/patroni/issues/1182)
[20] [https://xylentis.com](https://xylentis.com/blog/building-a-high-availability-postgresql-cluster-automated-failover-with-patroni-and-etcd-on-vps)
[21] [https://www.kubenatives.com](https://www.kubenatives.com/p/kubernetes-ha-quorum-split-brain)
[22] [https://patroni.readthedocs.io](https://patroni.readthedocs.io/en/latest/watchdog.html)
[23] [https://medium.com](https://medium.com/@guleribrahim/building-a-high-availability-postgresql-cluster-with-patroni-etcd-and-haproxy-77dc030e84d3)
[24] [https://www.cybertec-postgresql.com](https://www.cybertec-postgresql.com/en/introduction-and-how-to-etcd-clusters-for-patroni/)
[25] [https://patroni.readthedocs.io](https://patroni.readthedocs.io/en/latest/faq.html)
