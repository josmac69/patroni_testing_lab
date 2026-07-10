.PHONY: up down status ps logs clean write-test read-test failover client-logs ingest-docker ingest-local bootstrap bash psql help \
	triage dcs-dump simulate-leader-failure simulate-dcs-failure simulate-network-partition pause-cluster \
	recover-node recover-dcs recover-network-partition resume-cluster reinit-replica

NODE ?= patroni1
NUM ?= 1

help:
	@echo "Patroni HA Testing Lab Commands:"
	@echo "  make up                          - Build and start the cluster in the background"
	@echo "  make down                        - Stop the cluster containers"
	@echo "  make clean                       - Stop cluster and remove all volumes (wipes data!)"
	@echo "  make bootstrap                   - Run the realistic sequential cluster bootstrap process"
	@echo "  make status                      - Display Patroni cluster membership and replication state"
	@echo "  make ps                          - List running cluster containers"
	@echo "  make logs                        - Follow logs of all containers"
	@echo "  make client-logs                 - Follow logs of the background ingestion client"
	@echo "  make ingest-docker               - Run ingestion client interactively in a temp Docker container"
	@echo "  make ingest-local                - Run ingestion client locally on the host (sets up venv)"
	@echo "  make measure-loss-rate           - Run rate-limited RPO/RTO harness (e.g. RATE=60 DURATION=120)"
	@echo "  make failover                    - Run manual patronictl failover wizard"
	@echo "  make write-test [NUM=N]          - Run test SQL insert via HAProxy write port 5000 (default: NUM=1)"
	@echo "  make read-test                   - Run test SQL select via HAProxy read port 5001"
	@echo "  make bash                        - Open bash shell inside selected node (default: NODE=patroni1)"
	@echo "  make psql                        - Open psql shell inside selected node (default: NODE=patroni1)"
	@echo ""
	@echo "Triage & Diagnosis Commands:"
	@echo "  make triage                      - Run the deep triage and audit script on the running cluster"
	@echo "  make dcs-dump                    - Dump all Patroni keys directly from etcd"
	@echo ""
	@echo "Simulation & Failure Testing Commands:"
	@echo "  make simulate-leader-failure     - Detect current leader node and stop its container"
	@echo "  make simulate-dcs-failure        - Stop the etcd consensus container to simulate quorum loss"
	@echo "  make simulate-network-partition  - Disconnect the current leader from the cluster network"
	@echo "  make pause-cluster               - Pause Patroni auto-failover/supervision (maintenance mode)"
	@echo ""
	@echo "Recovery & Repair Commands:"
	@echo "  make recover-node NODE=<node>    - Start a stopped Patroni node container (e.g. NODE=patroni1)"
	@echo "  make recover-dcs                 - Start the etcd container and wait for it to be healthy"
	@echo "  make recover-network-partition   - Reconnect all cluster nodes back to the network"
	@echo "  make resume-cluster              - Resume Patroni auto-failover/supervision"
	@echo "  make reinit-replica NODE=<node>  - Reinitialize/re-clone a replica from scratch (e.g. NODE=patroni2)"

up:
	docker compose up --build -d

down:
	docker compose down

clean:
	docker compose down -v

status:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'patroni[1-3]' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list; \
	else \
		echo "No running Patroni nodes found. Try 'make ps' to check container status."; \
	fi

ps:
	docker compose ps

logs:
	docker compose logs -f

failover:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'patroni[1-3]' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec -it $$RUNNING patronictl -c /etc/patroni/patroni.yml failover; \
	else \
		echo "No running Patroni nodes found to run failover wizard."; \
	fi

write-test:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'patroni[1-3]' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING bash -c "PGPASSWORD=postgres_password psql -h patroni-haproxy -p 5000 -U postgres -d postgres -c \"INSERT INTO sensor_readings (sensor_name, reading_value) SELECT 'manual_test_sensor', 42.0 FROM generate_series(1, $(NUM));\""; \
	else \
		echo "No running Patroni nodes found to run write-test."; \
	fi

read-test:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'patroni[1-3]' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING bash -c "PGPASSWORD=postgres_password psql -h patroni-haproxy -p 5001 -U postgres -d postgres -c \"SELECT * FROM sensor_readings ORDER BY id DESC LIMIT 10;\""; \
	else \
		echo "No running Patroni nodes found to run read-test."; \
	fi

client-logs:
	docker compose logs -f client

ingest-docker:
	./scripts/run_ingestion.sh docker

ingest-local:
	./scripts/run_ingestion.sh local

measure-loss-rate:
	docker compose exec client python3 /scripts/rpo_rto_rate_harness.py --rate $(or $(RATE),60) --duration $(or $(DURATION),120)

bootstrap:
	./scripts/bootstrap.sh

bash:
	docker compose exec -u root -it $(NODE) bash

psql:
	docker compose exec -it $(NODE) psql -U postgres

# --- Triage & Diagnosis ---
triage:
	@echo "Running Patroni Deep Triage & Audit..."
	./scripts/patroni_deep_triage.sh

dcs-dump:
	@echo "Dumping Patroni cluster keys from etcd..."
	docker compose exec etcd etcdctl get --prefix /service/patroni-cluster

# --- Simulation of Issues ---
simulate-leader-failure:
	@echo "Detecting current cluster leader..."
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'patroni[1-3]' | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No running Patroni nodes found."; \
		exit 1; \
	fi; \
	LEADER=$$(docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
	if [ -z "$$LEADER" ]; then \
		echo "No active leader found in the cluster."; \
		exit 1; \
	fi; \
	echo "Simulating leader failure: stopping $$LEADER container..."; \
	docker compose stop $$LEADER

simulate-dcs-failure:
	@echo "Simulating DCS (etcd) outage by stopping the etcd container..."
	docker compose stop etcd

simulate-network-partition:
	@echo "Detecting current cluster leader..."
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'patroni[1-3]' | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No running Patroni nodes found."; \
		exit 1; \
	fi; \
	LEADER=$$(docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
	if [ -z "$$LEADER" ]; then \
		echo "No active leader found in the cluster."; \
		exit 1; \
	fi; \
	NET_NAME=$$(docker network ls --filter "name=patroni-net" --format "{{.Name}}" | head -n 1); \
	if [ -z "$$NET_NAME" ]; then \
		echo "Could not find Docker network name containing 'patroni-net'."; \
		exit 1; \
	fi; \
	echo "Simulating network partition for leader $$LEADER on network $$NET_NAME..."; \
	docker network disconnect $$NET_NAME $$LEADER

pause-cluster:
	@echo "Pausing automatic failover / cluster supervision..."
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'patroni[1-3]' | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No running Patroni nodes found."; \
		exit 1; \
	fi; \
	docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml pause patroni-cluster

# --- Recovery & Repair ---
recover-node:
	@if [ -z "$(NODE)" ]; then \
		echo "Please specify NODE to start (e.g. make recover-node NODE=patroni1)"; \
		exit 1; \
	fi
	@echo "Starting container $(NODE)..."
	docker compose start $(NODE)

recover-dcs:
	@echo "Restarting DCS (etcd) container..."
	docker compose start etcd
	@echo "Waiting for etcd to be healthy on port 2379..."
	@until docker compose exec etcd etcdctl endpoint health 2>/dev/null | grep -q 'healthy'; do \
		echo -n "."; \
		sleep 1; \
	done
	@echo " etcd is healthy."

recover-network-partition:
	@echo "Re-connecting all Patroni containers to the network to heal any partitions..."
	@NET_NAME=$$(docker network ls --filter "name=patroni-net" --format "{{.Name}}" | head -n 1); \
	if [ -z "$$NET_NAME" ]; then \
		echo "Could not find Docker network name containing 'patroni-net'."; \
		exit 1; \
	fi; \
	for node in patroni1 patroni2 patroni3; do \
		docker network connect $$NET_NAME $$node 2>/dev/null || true; \
	done; \
	echo "Network partition healed."

resume-cluster:
	@echo "Resuming automatic failover / cluster supervision..."
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'patroni[1-3]' | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No running Patroni nodes found."; \
		exit 1; \
	fi; \
	docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml resume patroni-cluster

reinit-replica:
	@if [ -z "$(NODE)" ]; then \
		echo "Please specify NODE to reinitialize (e.g. make reinit-replica NODE=patroni2)"; \
		exit 1; \
	fi
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'patroni[1-3]' | grep -v $(NODE) | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No other running Patroni nodes found to issue reinit command."; \
		exit 1; \
	fi; \
	echo "Issuing reinitialization command for $(NODE) via $$RUNNING..."; \
	docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml reinit patroni-cluster $(NODE)
