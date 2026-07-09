.PHONY: up down status ps logs clean write-test write-test-standby read-test-primary read-test-standby bootstrap help triage promote-standby \
	simulate-berlin-leader-failure simulate-bonn-leader-failure simulate-berlin-dcs-failure simulate-bonn-dcs-failure \
	simulate-network-partition-berlin simulate-network-partition-bonn pause-berlin resume-berlin pause-bonn resume-bonn \
	recover-node recover-berlin-dcs recover-bonn-dcs heal-network-partition reinit-node bash psql

NUM ?= 1
CLUSTER ?= berlin
NODE ?= berlin-patroni1

help:
	@echo "Multi-Cluster Patroni Standby Lab Commands:"
	@echo "  make bootstrap                   - Run sequential bootstrap process for berlin & bonn clusters"
	@echo "  make up                          - Start all containers in the background"
	@echo "  make down                        - Stop all cluster containers"
	@echo "  make clean                       - Stop containers and remove all volumes (wipes data!)"
	@echo "  make status                      - Display membership/replication state for BOTH clusters"
	@echo "  make ps                          - List all running containers"
	@echo "  make logs                        - Follow logs of all containers"
	@echo "  make bash [NODE=name]            - Open bash shell inside selected container (default: NODE=berlin-patroni1)"
	@echo "  make psql [NODE=name]            - Open psql shell inside selected container (default: NODE=berlin-patroni1)"
	@echo ""
	@echo "Database Testing Commands:"
	@echo "  make write-test [NUM=N]          - Insert N records via Berlin HAProxy (port 5000) (default: NUM=1)"
	@echo "  make write-test-standby [NUM=N]  - Try inserting N records via Bonn HAProxy (port 6000) (should fail)"
	@echo "  make read-test-primary           - Fetch latest records from Berlin HAProxy (port 5001)"
	@echo "  make read-test-standby           - Fetch latest records from Bonn HAProxy (port 6001)"
	@echo ""
	@echo "Triage & Maintenance Commands:"
	@echo "  make triage [CLUSTER=berlin|bonn] - Run deep triage audit on berlin or bonn cluster leader (default: CLUSTER=berlin)"
	@echo "  make promote-standby             - Promote Bonn (standby) cluster to standalone primary"
	@echo "  make pause-berlin                - Pause Patroni auto-failover/supervision for cluster_berlin"
	@echo "  make resume-berlin               - Resume Patroni auto-failover/supervision for cluster_berlin"
	@echo "  make pause-bonn                  - Pause Patroni auto-failover/supervision for cluster_bonn"
	@echo "  make resume-bonn                 - Resume Patroni auto-failover/supervision for cluster_bonn"
	@echo ""
	@echo "Simulation & Failure Testing Commands:"
	@echo "  make simulate-berlin-leader-failure  - Detect and stop the active berlin leader container"
	@echo "  make simulate-bonn-leader-failure    - Detect and stop the active bonn leader container"
	@echo "  make simulate-berlin-dcs-failure     - Stop berlin-etcd to simulate berlin DCS loss"
	@echo "  make simulate-bonn-dcs-failure       - Stop bonn-etcd to simulate bonn DCS loss"
	@echo "  make simulate-network-partition-berlin - Disconnect berlin leader from network"
	@echo "  make simulate-network-partition-bonn   - Disconnect bonn leader from network"
	@echo ""
	@echo "Recovery & Repair Commands:"
	@echo "  make recover-node NODE=<node>    - Start a stopped Patroni container (e.g. NODE=berlin-patroni1)"
	@echo "  make recover-berlin-dcs          - Restart berlin-etcd and wait for health check"
	@echo "  make recover-bonn-dcs            - Restart bonn-etcd and wait for health check"
	@echo "  make heal-network-partition      - Reconnect all containers to the network bridge"
	@echo "  make reinit-node NODE=<node>     - Reinitialize/re-clone a database node (e.g. NODE=berlin-patroni2)"

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
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'berlin-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list; \
	else \
		echo "No running Berlin Patroni nodes found."; \
	fi
	@echo ""
	@echo "=== STANDBY CLUSTER STATUS ==="
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'bonn-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list; \
	else \
		echo "No running Bonn Patroni nodes found."; \
	fi

ps:
	docker compose ps

logs:
	docker compose logs -f

write-test:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'berlin-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING bash -c "PGPASSWORD=postgres_password psql -h berlin-haproxy -p 5000 -U postgres -d postgres -c \"INSERT INTO sensor_readings (sensor_name, reading_value) SELECT 'manual_test_sensor', 42.0 FROM generate_series(1, $(NUM));\""; \
	else \
		echo "No running Berlin Patroni nodes found to run write-test."; \
	fi

write-test-standby:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'bonn-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING bash -c "PGPASSWORD=postgres_password psql -h bonn-haproxy -p 5000 -U postgres -d postgres -c \"INSERT INTO sensor_readings (sensor_name, reading_value) SELECT 'manual_test_sensor', 42.0 FROM generate_series(1, $(NUM));\""; \
	else \
		echo "No running Bonn Patroni nodes found to run write-test."; \
	fi

read-test-primary:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'berlin-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING bash -c "PGPASSWORD=postgres_password psql -h berlin-haproxy -p 5001 -U postgres -d postgres -c \"SELECT * FROM sensor_readings ORDER BY id DESC LIMIT 10;\""; \
	else \
		echo "No running Berlin Patroni nodes found to run read-test."; \
	fi

read-test-standby:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'bonn-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING bash -c "PGPASSWORD=postgres_password psql -h bonn-haproxy -p 5001 -U postgres -d postgres -c \"SELECT * FROM sensor_readings ORDER BY id DESC LIMIT 10;\""; \
	else \
		echo "No running Bonn Patroni nodes found to run read-test."; \
	fi

triage:
	@if [ "$(CLUSTER)" = "bonn" ] || [ "$(CLUSTER)" = "standby" ]; then \
		CONTAINER=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'bonn-patroni1' | head -n 1); \
		if [ -n "$$CONTAINER" ]; then \
			echo "Running Deep Triage on Bonn Cluster Leader ($$CONTAINER)..."; \
			PATRONI_CONTAINER=$$CONTAINER ./scripts/patroni_deep_triage.sh --url http://localhost:8008; \
		else \
			echo "Bonn leader (bonn-patroni1) is not running."; \
		fi \
	else \
		CONTAINER=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'berlin-patroni1' | head -n 1); \
		if [ -n "$$CONTAINER" ]; then \
			echo "Running Deep Triage on Berlin Cluster Leader ($$CONTAINER)..."; \
			PATRONI_CONTAINER=$$CONTAINER ./scripts/patroni_deep_triage.sh --url http://localhost:8008; \
		else \
			echo "Berlin leader (berlin-patroni1) is not running."; \
		fi \
	fi

promote-standby:
	@CONTAINER=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'bonn-patroni' | head -n 1); \
	if [ -n "$$CONTAINER" ]; then \
		echo "Promoting Bonn Cluster to Primary Cluster..."; \
		docker compose exec $$CONTAINER patronictl -c /etc/patroni/patroni.yml edit-config --set standby_cluster=null --force; \
	else \
		echo "No running Bonn Patroni nodes found to issue promotion."; \
	fi

# --- Simulation of Issues ---
simulate-berlin-leader-failure:
	@echo "Detecting current berlin cluster leader..."
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'berlin-patroni' | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No running Berlin Patroni nodes found."; \
		exit 1; \
	fi; \
	LEADER=$$(docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
	if [ -z "$$LEADER" ]; then \
		echo "No active leader found in the berlin cluster."; \
		exit 1; \
	fi; \
	echo "Stopping berlin leader $$LEADER..."; \
	docker compose stop $$LEADER

simulate-bonn-leader-failure:
	@echo "Detecting current bonn cluster leader..."
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'bonn-patroni' | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No running Bonn Patroni nodes found."; \
		exit 1; \
	fi; \
	LEADER=$$(docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list | grep "Standby Leader" | awk '{print $$2}'); \
	if [ -z "$$LEADER" ]; then \
		echo "No active standby leader found in the bonn cluster."; \
		exit 1; \
	fi; \
	echo "Stopping bonn leader $$LEADER..."; \
	docker compose stop $$LEADER

simulate-berlin-dcs-failure:
	@echo "Stopping Berlin DCS (berlin-etcd)..."
	docker compose stop berlin-etcd

simulate-bonn-dcs-failure:
	@echo "Stopping Bonn DCS (bonn-etcd)..."
	docker compose stop bonn-etcd

simulate-network-partition-berlin:
	@echo "Detecting current berlin cluster leader..."
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'berlin-patroni' | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No running Berlin Patroni nodes found."; \
		exit 1; \
	fi; \
	LEADER=$$(docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list | grep Leader | awk '{print $$2}'); \
	if [ -z "$$LEADER" ]; then \
		echo "No active leader found in the berlin cluster."; \
		exit 1; \
	fi; \
	NET_NAME=$$(docker network ls --filter "name=patroni-net" --format "{{.Name}}" | head -n 1); \
	echo "Simulating berlin leader network partition: disconnecting $$LEADER from $$NET_NAME..."; \
	docker network disconnect $$NET_NAME $$LEADER

simulate-network-partition-bonn:
	@echo "Detecting current bonn cluster leader..."
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'bonn-patroni' | head -n 1); \
	if [ -z "$$RUNNING" ]; then \
		echo "No running Bonn Patroni nodes found."; \
		exit 1; \
	fi; \
	LEADER=$$(docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml list | grep "Standby Leader" | awk '{print $$2}'); \
	if [ -z "$$LEADER" ]; then \
		echo "No active standby leader found in the bonn cluster."; \
		exit 1; \
	fi; \
	NET_NAME=$$(docker network ls --filter "name=patroni-net" --format "{{.Name}}" | head -n 1); \
	echo "Simulating bonn leader network partition: disconnecting $$LEADER from $$NET_NAME..."; \
	docker network disconnect $$NET_NAME $$LEADER

pause-berlin:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'berlin-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml pause cluster_berlin; \
	else \
		echo "No running Berlin Patroni nodes found."; \
	fi

resume-berlin:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'berlin-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml resume cluster_berlin; \
	else \
		echo "No running Berlin Patroni nodes found."; \
	fi

pause-bonn:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'bonn-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml pause cluster_bonn; \
	else \
		echo "No running Bonn Patroni nodes found."; \
	fi

resume-bonn:
	@RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'bonn-patroni' | head -n 1); \
	if [ -n "$$RUNNING" ]; then \
		docker compose exec $$RUNNING patronictl -c /etc/patroni/patroni.yml resume cluster_bonn; \
	else \
		echo "No running Bonn Patroni nodes found."; \
	fi

# --- Recovery & Repair ---
recover-node:
	@echo "Starting container $(NODE)..."
	docker compose start $(NODE)

recover-berlin-dcs:
	@echo "Starting berlin-etcd..."
	docker compose start berlin-etcd
	@until docker compose exec berlin-etcd etcdctl endpoint health 2>/dev/null | grep -q 'healthy'; do \
		echo -n "."; \
		sleep 1; \
	done
	@echo " berlin-etcd is healthy."

recover-bonn-dcs:
	@echo "Starting bonn-etcd..."
	docker compose start bonn-etcd
	@until docker compose exec bonn-etcd etcdctl endpoint health 2>/dev/null | grep -q 'healthy'; do \
		echo -n "."; \
		sleep 1; \
	done
	@echo " bonn-etcd is healthy."

heal-network-partition:
	@echo "Re-connecting all containers to patroni-net network..."
	@NET_NAME=$$(docker network ls --filter "name=patroni-net" --format "{{.Name}}" | head -n 1); \
	if [ -z "$$NET_NAME" ]; then \
		echo "Could not find Docker network name containing 'patroni-net'."; \
		exit 1; \
	fi; \
	for node in berlin-patroni1 berlin-patroni2 berlin-patroni3 bonn-patroni1 bonn-patroni2 bonn-patroni3; do \
		docker network connect $$NET_NAME $$node 2>/dev/null || true; \
	done; \
	echo "Network partitions healed."

reinit-node:
	@if [ -z "$(NODE)" ]; then \
		echo "Please specify NODE to reinitialize (e.g. make reinit-node NODE=berlin-patroni2)"; \
		exit 1; \
	fi
	@if echo "$(NODE)" | grep -q 'berlin'; then \
		CLUSTER_NAME="cluster_berlin"; \
		RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'berlin-patroni' | grep -v "$(NODE)" | head -n 1); \
	else \
		CLUSTER_NAME="cluster_bonn"; \
		RUNNING=$$(docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'bonn-patroni' | grep -v "$(NODE)" | head -n 1); \
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
