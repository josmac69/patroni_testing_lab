FROM python:3.12-slim
RUN pip install --no-cache-dir psycopg2-binary
WORKDIR /app
COPY ingest.py rpo_rto_harness.py /app/
CMD ["python", "-u", "ingest.py"]
