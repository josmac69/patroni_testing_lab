#!/usr/bin/env python3
"""RPO/RTO measurement harness.

Answers the two questions every client asks about an HA setup:

    RTO - how many seconds were writes unavailable during the failover?
    RPO - how many transactions that the client saw COMMITTED are gone
          after the failover?

Method
------
1. Insert sequence-numbered rows through HAProxy :5000 in a tight loop
   (autocommit, one row per transaction). Every sequence number for which
   the INSERT returned successfully is recorded in a local ledger - these
   are commits acknowledged to the client.
2. Trigger a failure in another terminal (e.g. `make scenario-failover`).
3. The harness detects the outage window: last successful commit before the
   first error, first successful commit after recovery. The difference is
   the measured RTO as experienced by the application.
4. After the run, it re-reads the table and diffs it against the ledger.
   Ledger entries missing from the table are acknowledged-but-lost commits:
   an RPO violation.

Expected teaching results
-------------------------
* asynchronous profile + hard leader kill  -> RPO usually > 0
* quorum profile (synchronous_mode: quorum) -> RPO = 0, slightly higher
  per-commit latency, slightly different RTO
* clean switchover (patronictl switchover)  -> RPO = 0 in both profiles

Usage
-----
    docker compose exec client python rpo_rto_harness.py --duration 120
Then trigger the failure while it runs.
"""
import argparse
import os
import sys
import time

import psycopg2

DSN = (
    f"host={os.environ.get('PGHOST', 'haproxy')} "
    f"port={os.environ.get('PGPORT', '5000')} "
    f"user={os.environ.get('PGUSER', 'postgres')} "
    f"password={os.environ.get('PGPASSWORD', 'postgres')} "
    f"dbname={os.environ.get('PGDATABASE', 'postgres')} "
    "connect_timeout=2 options='-c statement_timeout=2000'"
)

DDL = """
DROP TABLE IF EXISTS rpo_harness;
CREATE TABLE rpo_harness (
    seq         bigint PRIMARY KEY,
    inserted_at timestamptz NOT NULL DEFAULT now()
)
"""


def connect(retry=False):
    while True:
        try:
            conn = psycopg2.connect(DSN)
            conn.autocommit = True
            return conn
        except psycopg2.Error:
            if not retry:
                raise
            time.sleep(0.1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--duration", type=int, default=120,
                    help="run time in seconds (default 120)")
    ap.add_argument("--interval", type=float, default=0.05,
                    help="pause between inserts in seconds (default 0.05)")
    args = ap.parse_args()

    conn = connect()
    with conn.cursor() as cur:
        cur.execute(DDL)
    print(f"harness started: {args.duration}s at ~{1/args.interval:.0f} tx/s. "
          "Trigger the failure now.", flush=True)

    ledger = []          # sequence numbers acknowledged as committed
    outages = []         # (start_ts, end_ts) of write unavailability
    outage_start = None
    seq = 0
    deadline = time.monotonic() + args.duration

    while time.monotonic() < deadline:
        seq += 1
        try:
            with conn.cursor() as cur:
                cur.execute("INSERT INTO rpo_harness (seq) VALUES (%s)", (seq,))
            ledger.append(seq)
            if outage_start is not None:
                outages.append((outage_start, time.monotonic()))
                print(f"writes recovered after "
                      f"{outages[-1][1] - outages[-1][0]:.2f}s", flush=True)
                outage_start = None
        except psycopg2.Error:
            if outage_start is None:
                outage_start = time.monotonic()
                print("write outage detected...", flush=True)
            try:
                conn.close()
            except Exception:
                pass
            conn = connect(retry=True)
        time.sleep(args.interval)

    # --- verification phase -------------------------------------------------
    try:
        conn.close()
    except Exception:
        pass
    conn = connect(retry=True)
    with conn.cursor() as cur:
        cur.execute("SELECT seq FROM rpo_harness")
        in_table = {row[0] for row in cur.fetchall()}

    lost = [s for s in ledger if s not in in_table]

    print("\n===================== RESULTS =====================")
    print(f"acknowledged commits : {len(ledger)}")
    print(f"rows found in table  : {len(in_table)}")
    print(f"RPO violations       : {len(lost)} acknowledged commits lost")
    if lost:
        print(f"  lost sequence numbers: {lost[:20]}"
              f"{' ...' if len(lost) > 20 else ''}")
    if outages:
        for i, (a, b) in enumerate(outages, 1):
            print(f"RTO (outage {i})      : {b - a:.2f}s")
    else:
        print("RTO                  : no outage observed")
    print("===================================================")
    sys.exit(1 if lost else 0)


if __name__ == "__main__":
    main()
