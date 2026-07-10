# ===========================================================================
# Enhanced 3-node Patroni lab. Every target is documented; `make help` lists
# them. Scenario targets are thin wrappers around scripts/ so they can also
# be run and read individually.
# ===========================================================================
SHELL := /bin/bash
COMPOSE := docker compose

# Find a running Patroni node dynamically, fallback to patroni1 if none are running
RUNNING_NODE = $(shell docker compose ps --filter "status=running" --format "{{.Name}}" | grep -E 'patroni[1-3]' | head -n 1)
PATRONI_NODE = $(if $(RUNNING_NODE),$(RUNNING_NODE),patroni1)
PATRONICTL = $(COMPOSE) exec $(PATRONI_NODE) patronictl -c /tmp/patroni.yml

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}'

# --- lifecycle -------------------------------------------------------------
up: ## Build and start the whole stack
	$(COMPOSE) up -d --build
	./scripts/wait_for_cluster.sh
	@echo "Grafana:    http://localhost:3000  (dashboard 'Patroni Lab Overview')"
	@echo "Prometheus: http://localhost:9090"
	@echo "HAProxy:    http://localhost:7000"

down: ## Stop the stack, keep data volumes
	$(COMPOSE) down

clean: ## Stop the stack and DESTROY all data volumes
	$(COMPOSE) down -v

status: ## Cluster status via patronictl
	$(PATRONICTL) list

topology: ## Cluster topology including replication tree
	$(PATRONICTL) topology

config: ## Show current dynamic configuration stored in the DCS
	$(PATRONICTL) show-config

logs: ## Follow Patroni logs of all nodes
	$(COMPOSE) logs -f patroni1 patroni2 patroni3


# --- replication profiles (applied at runtime via the DCS) -----------------
profile-async: ## Default profile: asynchronous replication
	$(PATRONICTL) edit-config --force \
	  -s synchronous_mode=false \
	  -s 'synchronous_node_count=1'

profile-quorum: ## Patroni 4.x quorum commit: ANY 1 of the replicas must ack
	$(PATRONICTL) edit-config --force \
	  -s synchronous_mode=quorum \
	  -s 'synchronous_node_count=1'
	@echo "Verify on the primary: SHOW synchronous_standby_names; expect ANY 1 (...)"

profile-strict: ## synchronous_mode=on + strict: writes BLOCK with no sync standby
	$(PATRONICTL) edit-config --force \
	  -s synchronous_mode=true \
	  -s synchronous_mode_strict=true

profile-aggressive-timers: ## ttl=20 loop_wait=5 retry_timeout=5 (faster failover)
	$(PATRONICTL) edit-config --force -s ttl=20 -s loop_wait=5 -s retry_timeout=5

profile-default-timers: ## Restore textbook timers ttl=30/10/10
	$(PATRONICTL) edit-config --force -s ttl=30 -s loop_wait=10 -s retry_timeout=10

failsafe-on: ## Enable DCS failsafe mode (primary survives full DCS outage)
	$(PATRONICTL) edit-config --force -s failsafe_mode=true

failsafe-off: ## Disable DCS failsafe mode
	$(PATRONICTL) edit-config --force -s failsafe_mode=false

# --- scenarios -------------------------------------------------------------
scenario-failover: ## Hard-kill the current leader, watch automatic failover
	./scripts/scenario_failover.sh

scenario-switchover: ## Clean planned switchover (zero data loss expected)
	./scripts/scenario_switchover.sh

scenario-dcs-degraded: ## Stop 1 of 3 etcd nodes: quorum holds, nothing happens
	./scripts/scenario_dcs_quorum.sh degraded

scenario-dcs-quorum-loss: ## Stop 2 of 3 etcd nodes: primary demotes (unless failsafe)
	./scripts/scenario_dcs_quorum.sh lost

scenario-dcs-recover: ## Restart all etcd nodes
	./scripts/scenario_dcs_quorum.sh recover

scenario-failsafe-demo: ## Full guided demo: DCS loss with failsafe off, then on
	./scripts/scenario_failsafe.sh

scenario-partition-leader: ## Disconnect the leader from the network
	./scripts/scenario_partition_leader.sh partition

scenario-partition-heal: ## Reconnect the partitioned ex-leader (pg_rewind path)
	./scripts/scenario_partition_leader.sh heal

scenario-reinit-replica: ## Corrupt/remove a replica and reinitialize it
	./scripts/scenario_replica_rebuild.sh

# --- measurement -----------------------------------------------------------
measure-rpo-rto: ## Run the RPO/RTO harness for 120s; trigger a failure meanwhile
	$(COMPOSE) exec client python rpo_rto_harness.py --duration 120

pause: ## Patroni maintenance pause (Patroni stops managing PostgreSQL)
	$(PATRONICTL) pause

resume: ## Leave maintenance pause
	$(PATRONICTL) resume
