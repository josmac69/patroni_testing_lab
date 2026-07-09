.PHONY: up down status ps logs clean write-test write-test-standby read-test-primary read-test-standby bootstrap help triage promote-standby \
	simulate-primary-leader-failure simulate-standby-leader-failure simulate-primary-dcs-failure simulate-standby-dcs-failure \
	simulate-network-partition-primary simulate-network-partition-standby pause-primary resume-primary pause-standby resume-standby \
	recover-node recover-primary-dcs recover-standby-dcs heal-network-partition reinit-node bash psql

NUM ?= 1
CLUSTER ?= primary
NODE ?= primary-patroni1

help:
	@echo "Multi-Cluster Patroni Standby Lab Commands:"
	@echo "  make bootstrap                   - Run sequential bootstrap process for primary & standby clusters"
	@echo "  make up                          - Start all containers in the background"
	@echo "  make down                        - Stop all cluster containers"
	@echo "  make clean                       - Stop containers and remove all volumes (wipes data!)"
	@echo "  make status                      - Display membership/replication state for BOTH clusters"
	@echo "  make ps                          - List all running containers"
	@echo "  make logs                        - Follow logs of all containers"
	@echo "  make bash [NODE=name]            - Open bash shell inside selected container (default: NODE=primary-patroni1)"
	@echo "  make psql [NODE=name]            - Open psql shell inside selected container (default: NODE=primary-patroni1)"
	@echo ""
	@echo "Database Testing Commands:"
	@echo "  make write-test [NUM=N]          - Insert N records via Primary HAProxy (port 5000) (default: NUM=1)"
	@echo "  make write-test-standby [NUM=N]  - Try inserting N records via Standby HAProxy (port 6000) (should fail)"
	@echo "  make read-test-primary           - Fetch latest records from Primary HAProxy (port 5001)"
	@echo "  make read-test-standby           - Fetch latest records from Standby HAProxy (port 6001)"
	@echo ""
	@echo "Triage & Maintenance Commands:"
	@echo "  make triage [CLUSTER=primary|standby] - Run deep triage audit on primary or standby cluster leader (default: CLUSTER=primary)"
	@echo "  make promote-standby             - Promote Standby cluster to standalone primary"
	@echo "  make pause-primary               - Pause Patroni auto-failover/supervision for primary cluster"
	@echo "  make resume-primary              - Resume Patroni auto-failover/supervision for primary cluster"
	@echo "  make pause-standby               - Pause Patroni auto-failover/supervision for standby cluster"
	@echo "  make resume-standby              - Resume Patroni auto-failover/supervision for standby cluster"
	@echo ""
	@echo "Simulation & Failure Testing Commands:"
	@echo "  make simulate-primary-leader-failure  - Detect and stop the active primary leader container"
	@echo "  make simulate-standby-leader-failure  - Detect and stop the active standby leader container"
	@echo "  make simulate-primary-dcs-failure     - Stop primary-etcd to simulate primary DCS loss"
	@echo "  make simulate-standby-dcs-failure     - Stop standby-etcd to simulate standby DCS loss"
	@echo "  make simulate-network-partition-primary - Disconnect primary leader from network"
	@echo "  make simulate-network-partition-standby - Disconnect standby leader from network"
	@echo ""
	@echo "Recovery & Repair Commands:"
	@echo "  make recover-node NODE=<node>    - Start a stopped Patroni container (e.g. NODE=primary-patroni1)"
	@echo "  make recover-primary-dcs         - Restart primary-etcd and wait for health check"
	@echo "  make recover-standby-dcs         - Restart standby-etcd and wait for health check"
	@echo "  make heal-network-partition      - Reconnect all containers to the network bridge"
	@echo "  make reinit-node NODE=<node>     - Reinitialize/re-clone a database node (e.g. NODE=primary-patroni2)"

up:
	docker compose up --build -d

down:
	docker compose down

clean:
	docker compose down -v

bootstrap:
	./scripts/bootstrap.sh

status:
	@echo "=== PRIMARY CLUSTER STATUS ==="
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'primary-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list; \
	else \
		echo "No running primary Patroni nodes found."; \
	fi
	@echo ""
	@echo "=== STANDBY CLUSTER STATUS ==="
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'standby-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list; \
	else \
		echo "No running standby Patroni nodes found."; \
	fi

ps:
	docker compose ps

logs:
	docker compose logs -f

write-test:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'primary-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING bash -c "PGPASSWORD=postgres_password psql -h primary-haproxy -p 5000 -U postgres -d postgres -c \"INSERT INTO sensor_readings (sensor_name, reading_value) SELECT 'manual_test_sensor', 42.0 FROM generate_series(1, $(NUM));\""; \
	else \
		echo "No running primary Patroni nodes found to run write-test."; \
	fi

write-test-standby:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'standby-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING bash -c "PGPASSWORD=postgres_password psql -h standby-haproxy -p 5000 -U postgres -d postgres -c \"INSERT INTO sensor_readings (sensor_name, reading_value) SELECT 'manual_test_sensor', 42.0 FROM generate_series(1, $(NUM));\""; \
	else \
		echo "No running standby Patroni nodes found to run write-test."; \
	fi

read-test-primary:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'primary-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING bash -c "PGPASSWORD=postgres_password psql -h primary-haproxy -p 5001 -U postgres -d postgres -c \"SELECT * FROM sensor_readings ORDER BY id DESC LIMIT 10;\""; \
	else \
		echo "No running primary Patroni nodes found to run read-test."; \
	fi

read-test-standby:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'standby-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING bash -c "PGPASSWORD=postgres_password psql -h standby-haproxy -p 5001 -U postgres -d postgres -c \"SELECT * FROM sensor_readings ORDER BY id DESC LIMIT 10;\""; \
	else \
		echo "No running standby Patroni nodes found to run read-test."; \
	fi

triage:
	@if [ "$(CLUSTER)" = "standby" ]; then \
		CONTAINER=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'standby-patroni1' | head -n 1); \
		if [ -n "$$CONTAINER" ]; then \
			echo "Running Deep Triage on Standby Cluster Leader ($$CONTAINER)..."; \
			PATRONI_CONTAINER=$$CONTAINER ./scripts/patroni_deep_triage.sh --url http://localhost:8008; \
		else \
			echo "Standby leader (standby-patroni1) is not running."; \
		fi \
	else \
		CONTAINER=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'primary-patroni1' | head -n 1); \
		if [ -n "$$CONTAINER" ]; then \
			echo "Running Deep Triage on Primary Cluster Leader ($$CONTAINER)..."; \
			PATRONI_CONTAINER=$$CONTAINER ./scripts/patroni_deep_triage.sh --url http://localhost:8008; \
		else \
			echo "Primary leader (primary-patroni1) is not running."; \
		fi \
	fi

promote-standby:
	@CONTAINER=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'standby-patroni' | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		echo "Promoting Standby Cluster to Primary Cluster..."; \
		docker compose exec $$CONTAINER patronictl -c /etc/patroni/patroni.yml edit-config --set standby_cluster=null --force; \
	else \
		echo "No running standby Patroni nodes found to issue promotion."; \
	fi

# --- Simulation of Issues ---
simulate-primary-leader-failure:
	@echo "Detecting current primary cluster leader..."
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'primary-patroni' | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No running primary Patroni nodes found."; \
		exit 1; \
	fi; \
	LEADER=$$(docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
	if [ -z "$$LEADER" ]; then \
		echo "No active leader found in the primary cluster."; \
		exit 1; \
	fi; \
	echo "Stopping primary leader $$LEADER..."; \
	docker compose stop $$LEADER

simulate-standby-leader-failure:
	@echo "Detecting current standby cluster leader..."
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'standby-patroni' | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No running standby Patroni nodes found."; \
		exit 1; \
	fi; \
	LEADER=$$(docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list | grep "Standby Leader" | awk '{print $$2}'); \
	if [ -z "$$LEADER" ]; then \
		echo "No active standby leader found in the standby cluster."; \
		exit 1; \
	fi; \
	echo "Stopping standby leader $$LEADER..."; \
	docker compose stop $$LEADER

simulate-primary-dcs-failure:
	@echo "Stopping primary DCS (primary-etcd)..."
	docker compose stop primary-etcd

simulate-standby-dcs-failure:
	@echo "Stopping standby DCS (standby-etcd)..."
	docker compose stop standby-etcd

simulate-network-partition-primary:
	@echo "Detecting current primary cluster leader..."
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'primary-patroni' | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No running primary Patroni nodes found."; \
		exit 1; \
	fi; \
	LEADER=$$(docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
	if [ -z "$$LEADER" ]; then \
		echo "No active leader found in the primary cluster."; \
		exit 1; \
	fi; \
	NET_NAME=$$(docker network ls --filter "name=patroni-net" --format "{{.Name}}" | head -n 1); \
	echo "Simulating primary leader network partition: disconnecting $$LEADER from $$NET_NAME..."; \
	docker network disconnect $$NET_NAME $$LEADER

simulate-network-partition-standby:
	@echo "Detecting current standby cluster leader..."
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'standby-patroni' | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No running standby Patroni nodes found."; \
		exit 1; \
	fi; \
	LEADER=$$(docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list | grep "Standby Leader" | awk '{print $$2}'); \
	if [ -z "$$LEADER" ]; then \
		echo "No active standby leader found in the standby cluster."; \
		exit 1; \
	fi; \
	NET_NAME=$$(docker network ls --filter "name=patroni-net" --format "{{.Name}}" | head -n 1); \
	echo "Simulating standby leader network partition: disconnecting $$LEADER from $$NET_NAME..."; \
	docker network disconnect $$NET_NAME $$LEADER

pause-primary:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'primary-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml pause primary-cluster; \
	else \
		echo "No running primary Patroni nodes found."; \
	fi

resume-primary:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'primary-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml resume primary-cluster; \
	else \
		echo "No running primary Patroni nodes found."; \
	fi

pause-standby:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'standby-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml pause standby-cluster; \
	else \
		echo "No running standby Patroni nodes found."; \
	fi

resume-standby:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'standby-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml resume standby-cluster; \
	else \
		echo "No running standby Patroni nodes found."; \
	fi

# --- Recovery & Repair ---
recover-node:
	@echo "Starting container $(NODE)..."
	docker compose start $(NODE)

recover-primary-dcs:
	@echo "Starting primary-etcd..."
	docker compose start primary-etcd
	@until docker compose exec primary-etcd etcdctl endpoint health 2>/dev/null | grep -q 'healthy'; do \
		echo -n "."; \
		sleep 1; \
	done
	@echo " primary-etcd is healthy."

recover-standby-dcs:
	@echo "Starting standby-etcd..."
	docker compose start standby-etcd
	@until docker compose exec standby-etcd etcdctl endpoint health 2>/dev/null | grep -q 'healthy'; do \
		echo -n "."; \
		sleep 1; \
	done
	@echo " standby-etcd is healthy."

heal-network-partition:
	@echo "Re-connecting all containers to patroni-net network..."
	@NET_NAME=$$(docker network ls --filter "name=patroni-net" --format "{{.Name}}" | head -n 1); \
	if [ -z "$$NET_NAME" ]; then \
		echo "Could not find Docker network name containing 'patroni-net'."; \
		exit 1; \
	fi; \
	for node in primary-patroni1 primary-patroni2 primary-patroni3 standby-patroni1 standby-patroni2 standby-patroni3; do \
		docker network connect $$NET_NAME $$node 2>/dev/null || true; \
	done; \
	echo "Network partitions healed."

reinit-node:
	@if [ -z "$(NODE)" ]; then \
		echo "Please specify NODE to reinitialize (e.g. make reinit-node NODE=primary-patroni2)"; \
		exit 1; \
	fi
	@if echo "$(NODE)" | grep -q 'primary'; then \
		CLUSTER_NAME="primary-cluster"; \
		RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'primary-patroni' | grep -v "$(NODE)" | head -n 1); \
	else \
		CLUSTER_NAME="standby-cluster"; \
		RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'standby-patroni' | grep -v "$(NODE)" | head -n 1); \
	fi; \
	if [ -z "$$RUNNING" ]; then \
		echo "No other running nodes found in the target cluster to run reinit."; \
		exit 1; \
	fi; \
	echo "Reinitializing $(NODE) via $$RUNNING..."; \
	docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml reinit $$CLUSTER_NAME $(NODE)

bash:
	docker compose exec -u root -it $(NODE) bash

psql:
	docker compose exec -it $(NODE) psql -U postgres
