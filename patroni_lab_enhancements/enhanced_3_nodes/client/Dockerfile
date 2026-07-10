FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir psycopg2-binary
WORKDIR /app
COPY ingest.py rpo_rto_harness.py rpo_rto_rate_harness.py /app/
CMD ["python", "-u", "ingest.py"]
