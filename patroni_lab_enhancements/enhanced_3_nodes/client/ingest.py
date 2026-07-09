#!/usr/bin/env python3
"""Continuous mock sensor ingestion through HAProxy (:5000, write endpoint).

Purpose in the lab: provide a steady, visible write workload so that every
failure scenario has observable consequences (errors in this log, gaps in the
Grafana commit-rate panel). One row per second, reconnects forever.

For quantitative RPO/RTO measurement use rpo_rto_harness.py instead - this
client only shows *that* writes fail, not *how much* was lost.
"""
import os
import random
import time

import psycopg2

DSN = (
    f"host={os.environ.get('PGHOST', 'haproxy')} "
    f"port={os.environ.get('PGPORT', '5000')} "
    f"user={os.environ.get('PGUSER', 'postgres')} "
    f"password={os.environ.get('PGPASSWORD', 'postgres')} "
    f"dbname={os.environ.get('PGDATABASE', 'postgres')} "
    "connect_timeout=3"
)

DDL = """
CREATE TABLE IF NOT EXISTS sensor_data (
    id          bigserial PRIMARY KEY,
    sensor_id   int         NOT NULL,
    temperature numeric(5,2) NOT NULL,
    humidity    numeric(5,2) NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT now()
)
"""


def connect():
    while True:
        try:
            conn = psycopg2.connect(DSN)
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(DDL)
            print("connected, ingesting one row per second", flush=True)
            return conn
        except psycopg2.Error as exc:
            print(f"connect failed: {exc}".strip(), flush=True)
            time.sleep(1)


def main():
    conn = connect()
    while True:
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO sensor_data (sensor_id, temperature, humidity) "
                    "VALUES (%s, %s, %s) RETURNING id",
                    (
                        random.randint(1, 50),
                        round(random.uniform(15.0, 35.0), 2),
                        round(random.uniform(20.0, 90.0), 2),
                    ),
                )
                row_id = cur.fetchone()[0]
                print(f"inserted id={row_id}", flush=True)
        except psycopg2.Error as exc:
            print(f"write failed: {exc}".strip(), flush=True)
            try:
                conn.close()
            except Exception:
                pass
            conn = connect()
        time.sleep(1)


if __name__ == "__main__":
    main()
