.PHONY: up down status ps logs clean write-test read-test failover client-logs ingest-docker ingest-local bootstrap bash psql help

NODE ?= patroni1

help:
	@echo "Patroni HA Testing Lab Commands:"
	@echo "  make up            - Build and start the cluster in the background"
	@echo "  make down          - Stop the cluster containers"
	@echo "  make clean         - Stop cluster and remove all volumes (wipes data!)"
	@echo "  make bootstrap     - Run the realistic sequential cluster bootstrap process"
	@echo "  make status        - Display Patroni cluster membership and replication state"
	@echo "  make ps            - List running cluster containers"
	@echo "  make logs          - Follow logs of all containers"
	@echo "  make client-logs   - Follow logs of the background ingestion client"
	@echo "  make ingest-docker - Run ingestion client interactively in a temp Docker container"
	@echo "  make ingest-local  - Run ingestion client locally on the host (sets up venv)"
	@echo "  make failover      - Run manual patronictl failover wizard"
	@echo "  make write-test    - Run test SQL insert via HAProxy write port 5000"
	@echo "  make read-test     - Run test SQL select via HAProxy read port 5001"
	@echo "  make bash          - Open bash shell inside selected node (default: NODE=patroni1)"
	@echo "  make psql          - Open psql shell inside selected node (default: NODE=patroni1)"

up:
	docker compose up --build -d

down:
	docker compose down

clean:
	docker compose down -v

status:
	docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml list

ps:
	docker compose ps

logs:
	docker compose logs -f

failover:
	docker compose exec patroni1 patronictl -c /etc/patroni/patroni.yml failover

write-test:
	docker compose exec patroni1 bash -c "PGPASSWORD=postgres_password psql -h patroni-haproxy -p 5000 -U postgres -d postgres -c \"INSERT INTO test_ha (val) VALUES ('Test insertion at \$$(date)');\""

read-test:
	docker compose exec patroni1 bash -c "PGPASSWORD=postgres_password psql -h patroni-haproxy -p 5001 -U postgres -d postgres -c \"SELECT * FROM test_ha;\""

client-logs:
	docker compose logs -f client

ingest-docker:
	./scripts/run_ingestion.sh docker

ingest-local:
	./scripts/run_ingestion.sh local

bootstrap:
	./scripts/bootstrap.sh

bash:
	docker compose exec -it $(NODE) bash

psql:
	docker compose exec -it $(NODE) psql -U postgres




