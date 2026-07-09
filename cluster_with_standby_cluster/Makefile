.PHONY: up down status ps logs clean write-test write-test-standby read-test-primary read-test-standby bootstrap help triage promote-standby

NUM ?= 1
CLUSTER ?= primary

help:
	@echo "Multi-Cluster Patroni Standby Lab Commands:"
	@echo "  make bootstrap                   - Run sequential bootstrap process for primary & standby clusters"
	@echo "  make up                          - Start all containers in the background"
	@echo "  make down                        - Stop all cluster containers"
	@echo "  make clean                       - Stop containers and remove all volumes (wipes data!)"
	@echo "  make status                      - Display membership/replication state for BOTH clusters"
	@echo "  make ps                          - List all running containers"
	@echo "  make logs                        - Follow logs of all containers"
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
