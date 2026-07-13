# Timeline in PostgreSQL Streaming Replication

In PostgreSQL streaming replication, a timeline is a unique identifier that tracks the history of a database cluster's Write-Ahead Log (WAL) records and identifies points where the transaction history diverges. [1, 2]
Timeline is like a parallel universe indicator for your data. It ensures that if a database changes direction (e.g., after a replica is promoted to primary), the old and new transaction streams do not mix or overwrite each other. [2, 3, 4]
------------------------------
## 🗺️ Why Timelines Exist
By default, a brand-new PostgreSQL database begins on Timeline 1. As long as the primary database runs normally, it writes WAL files continuously along this single path. [2]
However, if the primary server crashes and you promote a standby replica to take its place, that standby opens up for new write transactions. To prevent its new data from colliding with any potential un-replicated data from the dead primary, PostgreSQL increments the Timeline ID to Timeline 2. [2, 5, 6, 7]
## 🔍 How Timelines Work in Streaming Replication## 1. Decoupled WAL Naming
You can see the current timeline ID directly inside your pg_wal directory. Every WAL segment file name is a 24-character hexadecimal string. The first 8 characters represent the Timeline ID: [1, 4, 8, 9]

* 000000010000000000000001 → Timeline 1
* 000000020000000000000001 → Timeline 2 (created after a replica promotion or Point-in-Time Recovery) [2, 4]

## 2. History Files (.history)
When a new timeline is spawned, PostgreSQL creates a small text file called a timeline history file (e.g., 00000002.history). This file acts as a birth certificate. It records exactly: [6, 10]

* Which timeline it branched off from (the parent timeline).
* The exact Log Sequence Number (LSN) position where the split happened. [1, 11]

## 3. Re-Syncing Other Standbys
In modern PostgreSQL streaming replication, when a primary is promoted, other surviving standby replicas can automatically switch timelines to follow the new primary. The standby's WAL receiver process pulls the new .history file from the new primary, reads the branching point, and safely rolls over to stream the new timeline's WAL records. [3, 10, 12, 13, 14]
------------------------------
## ⚙️ Critical Settings
To ensure smooth operations across timeline changes, make sure your configurations are set correctly:

* recovery_target_timeline = 'latest': This parameter tells a standby database to automatically seek out and follow the newest timeline found in the stream or archive. (Note: This has been the default behavior since PostgreSQL 12). [15, 16, 17]
* primary_conninfo: When performing a failover, you must update this connection string on remaining standby nodes to point to the new primary host so they can begin fetching the updated timeline. [12, 16]


[1] [https://www.highgo.ca](https://www.highgo.ca/2021/11/01/the-postgresql-timeline-concept/)
[2] [https://tomasz-gintowt.medium.com](https://tomasz-gintowt.medium.com/postgresql-timelines-for-beginners-877f94e8b315)
[3] [https://av.tib.eu](https://av.tib.eu/media/19063)
[4] [https://www.linkedin.com](https://www.linkedin.com/pulse/what-postgresql-timelines-how-do-work-distributed-system-sahu-6bx9c)
[5] [https://www.cybertec-postgresql.com](https://www.cybertec-postgresql.com/wp-content/uploads/2024/02/PostgreSQL_understanding_replication.pdf)
[6] [https://postgreshelp.com](https://postgreshelp.com/postgresql-timelines/)
[7] [https://www.tigerdata.com](https://www.tigerdata.com/learn/best-practices-for-postgres-database-replication)
[8] [https://oneuptime.com](https://oneuptime.com/blog/post/2026-03-02-how-to-configure-postgresql-write-ahead-log-wal-on-ubuntu/view)
[9] [https://www.enterprisedb.com](https://www.enterprisedb.com/docs/pgd/4.4/bdr/nodes/)
[10] [https://www.postgresql.org](https://www.postgresql.org/docs/9.3/protocol-replication.html)
[11] [https://www.postgresql.org](https://www.postgresql.org/docs/current/continuous-archiving.html)
[12] [https://www.youtube.com](https://www.youtube.com/watch?v=NaPnYQBBdyU)
[13] [https://www.postgresql.org](https://www.postgresql.org/message-id/504F737E.1040103%40iki.fi)
[14] [https://www.youtube.com](https://www.youtube.com/watch?v=OBe_w7XlcqU&t=98)
[15] [https://www.alibabacloud.com](https://www.alibabacloud.com/blog/how-to-avoid-timeline-errors-during-database-switchover-based-on-asynchronous-streaming-replication_597819)
[16] [https://www.postgresql.org](https://www.postgresql.org/docs/current/warm-standby.html)
[17] [https://www.digitalocean.com](https://www.digitalocean.com/community/tutorials/how-to-set-up-continuous-archiving-and-perform-point-in-time-recovery-with-postgresql-12-on-ubuntu-20-04)
