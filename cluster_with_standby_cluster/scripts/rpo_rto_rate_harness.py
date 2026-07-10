#!/usr/bin/env python3
"""RPO/RTO rate-limited measurement harness.

Sends a constant rate of inserts per minute to the cluster and counts any lost
inserts (RPO violations) and outage durations (RTO) during switchover/failover.
"""
import argparse
import os
import sys
import time
import psycopg2

# ANSI colors
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[0;33m'
BLUE = '\033[0;34m'
CYAN = '\033[0;36m'
BOLD = '\033[1m'
NC = '\033[0m'

DDL = """
DROP TABLE IF EXISTS rpo_rate_harness;
CREATE TABLE rpo_rate_harness (
    seq         bigint PRIMARY KEY,
    inserted_at timestamptz NOT NULL DEFAULT now()
)
"""

def connect(host, port, user, password, dbname, retry=False):
    passwords_to_try = [password] if password else []
    if not passwords_to_try:
        if 'PGPASSWORD' in os.environ:
            passwords_to_try.append(os.environ['PGPASSWORD'])
        else:
            # Common passwords in the lab: 'postgres' (enhanced_3_nodes) and 'postgres_password' (classic/standby)
            passwords_to_try.extend(['postgres', 'postgres_password'])

    last_err = None
    while True:
        for pwd in passwords_to_try:
            try:
                dsn = (
                    f"host={host} port={port} user={user} password={pwd} dbname={dbname} "
                    "connect_timeout=2 options='-c statement_timeout=2000'"
                )
                conn = psycopg2.connect(dsn)
                conn.autocommit = True
                return conn, pwd
            except psycopg2.Error as e:
                last_err = e
                # If it's not a password auth error, don't try other passwords
                if "authentication failed" not in str(e):
                    break
        if not retry:
            raise last_err
        time.sleep(0.1)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rate", "-r", type=float, default=60.0,
                    help="inserts per minute (default: 60)")
    ap.add_argument("--duration", "-d", type=int, default=120,
                    help="run time in seconds (default: 120)")
    ap.add_argument("--host", default=os.environ.get("PGHOST", "localhost"),
                    help="database host (default: localhost / env PGHOST)")
    ap.add_argument("--port", default=os.environ.get("PGPORT", "5000"),
                    help="database port (default: 5000 / env PGPORT)")
    ap.add_argument("--user", default=os.environ.get("PGUSER", "postgres"),
                    help="database user (default: postgres / env PGUSER)")
    ap.add_argument("--password", default=os.environ.get("PGPASSWORD", ""),
                    help="database password")
    ap.add_argument("--dbname", default=os.environ.get("PGDATABASE", "postgres"),
                    help="database name (default: postgres / env PGDATABASE)")
    args = ap.parse_args()

    # Calculate intervals
    if args.rate <= 0:
        print(f"{RED}Error: Rate must be greater than 0.{NC}", file=sys.stderr)
        sys.exit(2)

    interval = 60.0 / args.rate
    print(f"{BLUE}Connecting to database to initialize table...{NC}")
    
    try:
        conn, active_pwd = connect(args.host, args.port, args.user, args.password, args.dbname)
    except Exception as e:
        # If localhost fails, try 'haproxy' (common hostname inside docker container)
        if args.host == "localhost":
            try:
                conn, active_pwd = connect("haproxy", args.port, args.user, args.password, args.dbname)
                args.host = "haproxy"
            except Exception:
                raise e
        else:
            raise e

    with conn.cursor() as cur:
        cur.execute(DDL)
    
    print(f"\n{BOLD}{GREEN}Harness started!{NC}")
    print(f"Target rate  : {args.rate} inserts/minute (~one every {interval:.3f}s)")
    print(f"Duration     : {args.duration} seconds")
    print(f"Endpoint     : {args.host}:{args.port}")
    print(f"{CYAN}Trigger the switchover/failover now!{NC}\n")

    ledger = []          # sequence numbers acknowledged as committed
    outages = []         # (start_ts, end_ts) of write unavailability
    outage_start = None
    seq = 0
    
    start_time = time.monotonic()
    deadline = start_time + args.duration

    while time.monotonic() < deadline:
        seq += 1
        target_time = start_time + (seq * interval)
        
        try:
            with conn.cursor() as cur:
                cur.execute("INSERT INTO rpo_rate_harness (seq) VALUES (%s)", (seq,))
            ledger.append(seq)
            print(f"[{time.strftime('%H:%M:%S')}] INGESTED: seq={seq}", flush=True)
            
            if outage_start is not None:
                outage_duration = time.monotonic() - outage_start
                outages.append((outage_start, time.monotonic()))
                print(f"{GREEN}✅ writes recovered after {outage_duration:.2f}s{NC}", flush=True)
                outage_start = None
        except psycopg2.Error as e:
            if outage_start is None:
                outage_start = time.monotonic()
                print(f"{YELLOW}⚠️  write outage detected: {str(e).strip()}{NC}", flush=True)
            try:
                conn.close()
            except Exception:
                pass
            conn, active_pwd = connect(args.host, args.port, args.user, active_pwd, args.dbname, retry=True)
        
        # Sleep until the next scheduled target time
        now = time.monotonic()
        sleep_time = target_time - now
        if sleep_time > 0:
            time.sleep(sleep_time)

    # --- verification phase -------------------------------------------------
    print(f"\n{BLUE}Outage completed. Verifying results...{NC}")
    try:
        conn.close()
    except Exception:
        pass
    
    conn, active_pwd = connect(args.host, args.port, args.user, active_pwd, args.dbname, retry=True)
    with conn.cursor() as cur:
        cur.execute("SELECT seq FROM rpo_rate_harness")
        in_table = {row[0] for row in cur.fetchall()}

    lost = [s for s in ledger if s not in in_table]

    print(f"\n{BOLD}===================== RESULTS ====================={NC}")
    print(f"Target rate          : {args.rate} inserts/minute")
    print(f"Acknowledged commits : {len(ledger)}")
    print(f"Rows found in table  : {len(in_table)}")
    
    if lost:
        print(f"RPO violations       : {RED}{len(lost)} acknowledged commits lost{NC}")
        print(f"  lost sequence numbers: {lost[:20]}{' ...' if len(lost) > 20 else ''}")
    else:
        print(f"RPO violations       : {GREEN}0 (No data loss!){NC}")
        
    if outages:
        for i, (a, b) in enumerate(outages, 1):
            print(f"RTO (outage {i})      : {YELLOW}{b - a:.2f}s{NC}")
    else:
        print(f"RTO                  : {GREEN}no outage observed{NC}")
    print(f"{BOLD}==================================================={NC}")
    sys.exit(1 if lost else 0)

if __name__ == "__main__":
    main()
