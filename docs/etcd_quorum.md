# Quorum of 3 etcd nodes

In a 3-node cluster, the quorum (majority) required to make decisions is 2 nodes. As long as at least 2 nodes can talk to each other, they will hold an election, choose a leader, and the cluster will remain fully operational. [1, 2, 3, 4]

Here is exactly how that plays out under different scenarios:
## 1. Normal Operations (3 Nodes Healthy)

* Status: 1 Leader, 2 Followers.
* Mechanism: The leader constantly sends heartbeats to the 2 followers, maintaining its authority. [5, 6, 7]

## 2. Failure Scenario A: One Follower Dies

* Nodes Alive: 2 out of 3.
* Status: 1 Leader, 1 Follower.
* Quorum Met?: Yes (2 ≥ 2).
* The remaining 2 nodes still represent a majority. The Leader stays the leader, and the cluster continues to process both reads and writes normally. [8, 9, 10, 11, 12]

## 3. Failure Scenario B: The Leader Dies

* Nodes Alive: 2 out of 3 (both are currently Followers).
* Status: Transiently 0 leaders, then 1 new Leader elected.
* Quorum Met?: Yes (2 ≥ 2).
* Mechanism: The 2 remaining followers stop receiving heartbeats. Their election timers expire, and they transition to Candidates. They vote, and because they only need 2 votes to form a quorum, one of them will successfully become the new Leader. [13, 14, 15, 16, 17]

## 4. Failure Scenario C: Two Nodes Die (Quorum Lost)

* Nodes Alive: 1 out of 3.
* Status: 0 Leaders.
* Quorum Met?: No (1 < 2).
* Mechanism: If a network partition or crash leaves only 1 node alive, it cannot achieve the 2 votes needed for a quorum. If it was the leader, it will step down. The cluster freezes and will refuse to process any new write operations until at least one more node rejoins. [18, 19, 20, 21]

[1] [https://www.siderolabs.com](https://www.siderolabs.com/blog/why-should-a-kubernetes-control-plane-be-three-nodes)
[2] [https://www.elastic.co](https://www.elastic.co/docs/deploy-manage/distributed-architecture/discovery-cluster-formation/modules-discovery-voting)
[3] [https://www.axoniq.io](https://www.axoniq.io/blog/high-availability-with-axonserver-and-axon-framework)
[4] [https://designgurus.substack.com](https://designgurus.substack.com/p/system-design-essentials-learn-split)
[5] [https://pulse.support](https://pulse.support/kb/opensearch-node-types-explained)
[6] [https://engineering.cred.club](https://engineering.cred.club/dynamodb-internals-90c87184ab88)
[7] [https://www.linkedin.com](https://www.linkedin.com/pulse/understanding-leader-election-raft-consensus-rakshith-rajkumar-ca9te)
[8] [https://syntegrity.com.au](https://syntegrity.com.au/dealing-with-rdqm-cluster-loss-part-1-recovery/)
[9] [https://learn.microsoft.com](https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/quorum)
[10] [https://www.sqlshack.com](https://www.sqlshack.com/iscsi-iscsi-initiator-quorum-configuration-and-sql-server-cluster-installation/)
[11] [https://pulse.support](https://pulse.support/kb/opensearch-node-types-explained)
[12] [https://medium.com](https://medium.com/@extio/deep-dive-into-etcd-a-distributed-key-value-store-a6a7699d3abc)
[13] [https://syntegrity.com.au](https://syntegrity.com.au/dealing-with-rdqm-cluster-loss-part-1-recovery/)
[14] [https://daein.medium.com](https://daein.medium.com/introduction-what-is-the-etcd-95ec25b633db)
[15] [https://layrs.me](https://layrs.me/course/hld/11-cloud-design-patterns/leader-election/)
[16] [https://a-nikishaev.medium.com](https://a-nikishaev.medium.com/beyond-possible-scale-how-aws-dynamodb-was-built-a-deep-dive-a9235ed742bc)
[17] [https://credera.com](https://credera.com/en-us/insights/when-do-dags-need-a-file-share-witness)
[18] [https://dev.to](https://dev.to/aws-builders/avoid-this-costly-aws-opensearch-mistake-the-complete-guide-to-quorum-loss-77j)
[19] [https://www.kubenatives.com](https://www.kubenatives.com/p/kubernetes-ha-quorum-split-brain)
[20] [https://etcd.io](https://etcd.io/docs/v3.5/op-guide/failures/)
[21] [https://pulse.support](https://pulse.support/kb/opensearch-node-types-explained)
