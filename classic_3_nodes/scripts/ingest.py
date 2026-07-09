import os
import time
import random
import psycopg2
import sys

DB_HOST = os.environ.get("DB_HOST", "patroni-haproxy")
DB_PORT = os.environ.get("DB_PORT", "5000")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "postgres_password")
DB_NAME = os.environ.get("DB_NAME", "postgres")

DB_URI = f"postgres://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
SENSOR_NAMES = ["temp_sensor_1", "temp_sensor_2", "pressure_sensor_1", "humidity_sensor_1"]

def setup_database(conn):
    """Ensure the schema is created on the primary database."""
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS sensor_readings (
                id SERIAL PRIMARY KEY,
                sensor_name VARCHAR(50) NOT NULL,
                reading_value DOUBLE PRECISION NOT NULL,
                recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        """)
        conn.commit()
    print("Database schema verified/created successfully.")

def main():
    print("Starting Patroni Replication Ingestion Client...")
    
    max_records = os.environ.get("MAX_RECORDS")
    if max_records is not None:
        try:
            max_records = int(max_records)
            print(f"Ingestion limit set to {max_records} records.")
        except ValueError:
            print(f"Warning: Invalid MAX_RECORDS value '{max_records}', ignoring limit.")
            max_records = None

    records_inserted = 0
    conn = None
    
    while True:
        try:
            if conn is None or conn.closed:
                print(f"Connecting to database at {DB_URI}...")
                conn = psycopg2.connect(DB_URI)
                setup_database(conn)
                print("Connected and ready.")
            
            # Generate and insert mock data
            sensor = random.choice(SENSOR_NAMES)
            value = round(random.uniform(20.0, 100.0) if "temp" in sensor or "humidity" in sensor else random.uniform(100.0, 150.0), 2)
            
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO sensor_readings (sensor_name, reading_value) VALUES (%s, %s) RETURNING id, recorded_at;",
                    (sensor, value)
                )
                row_id, recorded_at = cur.fetchone()
                conn.commit()
                print(f"[{recorded_at}] INGESTED: ID={row_id} | {sensor} = {value}")
            
            records_inserted += 1
            if max_records is not None and records_inserted >= max_records:
                print(f"Ingestion complete. Reached limit of {max_records} records.")
                if conn:
                    conn.close()
                break

            time.sleep(1.0)
            
        except psycopg2.OperationalError as e:
            print(f"Operational error: {e}", file=sys.stderr)
            print("Database connection lost. Reconnecting in 2 seconds...", file=sys.stderr)
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass
            conn = None
            time.sleep(2.0)
            
        except Exception as e:
            print(f"Unexpected error: {e}", file=sys.stderr)
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass
            conn = None
            time.sleep(2.0)

if __name__ == "__main__":
    main()
