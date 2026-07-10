#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Check if enhanced_3_nodes stack is up
COMPOSE_FILE="../enhanced_3_nodes/docker-compose.yml"
if ! docker compose -f "$COMPOSE_FILE" ps | grep -q "patroni"; then
    echo -e "${RED}${BOLD}Error: The flagship lab is not running!${NC}"
    echo -e "Please start the stack first by running:"
    echo -e "  ${CYAN}cd ../enhanced_3_nodes && make up${NC}"
    exit 1
fi

show_header() {
    clear
    echo -e "${BLUE}${BOLD}========================================================================${NC}"
    echo -e "${BLUE}${BOLD}                      PATRONI CHAOS DEMO UTILITY                       ${NC}"
    echo -e "${BLUE}${BOLD}========================================================================${NC}"
}

pause_for_user() {
    echo ""
    read -p "Press [Enter] to run the experiment..."
}

run_slow_dcs() {
    show_header
    echo -e "${YELLOW}${BOLD}Scenario 1: Slow DCS response (etcd latency)${NC}"
    echo -e "This scenario simulates slow network conditions between Patroni nodes and etcd."
    echo -e "With aggressive timers, this will cause leader lease renewal to fail, triggering demotion."
    echo ""
    echo -e "Under normal conditions, you would execute these manual commands:"
    echo -e "  ${GREEN}./pumba/netem_delay.sh etcd1 800 60s${NC}"
    echo -e "  ${GREEN}./pumba/netem_delay.sh etcd2 800 60s${NC}"
    echo -e "  ${GREEN}./pumba/netem_delay.sh etcd3 800 60s${NC}"
    
    pause_for_user

    echo -e "\n${CYAN}Executing delay injection...${NC}"
    ./pumba/netem_delay.sh etcd1 800 60s &
    ./pumba/netem_delay.sh etcd2 800 60s &
    ./pumba/netem_delay.sh etcd3 800 60s &
    wait
    
    echo -e "\n${GREEN}Experiment finished.${NC}"
    echo -e "Check Patroni cluster status now:"
    echo -e "  ${CYAN}docker compose -f $COMPOSE_FILE exec patroni1 patronictl -c /tmp/patroni.yml list${NC}"
    read -p "Press [Enter] to return to menu..."
}

run_loss() {
    show_header
    echo -e "${YELLOW}${BOLD}Scenario 2: Replication Link Packet Loss${NC}"
    echo -e "This scenario injects 15% packet loss on patroni2 to simulate physical network degradation."
    echo -e "You will see replication lag grow on Grafana."
    echo ""
    echo -e "Manual command:"
    echo -e "  ${GREEN}./pumba/netem_loss.sh patroni2 15 60s${NC}"
    
    pause_for_user

    echo -e "\n${CYAN}Executing packet loss injection on patroni2...${NC}"
    ./pumba/netem_loss.sh patroni2 15 60s
    
    echo -e "\n${GREEN}Experiment finished.${NC}"
    echo -e "Check replication lag or cluster status:"
    echo -e "  ${CYAN}docker compose -f $COMPOSE_FILE exec patroni1 patronictl -c /tmp/patroni.yml list${NC}"
    read -p "Press [Enter] to return to menu..."
}

run_freeze() {
    show_header
    echo -e "${YELLOW}${BOLD}Scenario 3: Process Freeze (SIGSTOP Watchdog Test)${NC}"
    echo -e "This pauses the leader container. The leader key will expire in etcd, prompting standbys"
    echo -e "to elect a new leader. When the ex-leader unfreezes, the watchdog will force-restart/demote it."
    echo ""
    
    # Dynamically find current leader
    LEADER=$(docker compose -f "$COMPOSE_FILE" exec -T patroni1 patronictl -c /tmp/patroni.yml list -f json | grep -B2 '"Role": "Leader"' | grep '"Name"' | cut -d'"' -f4 | head -n1 || echo "patroni1")
    
    echo -e "Current detected leader: ${BOLD}$LEADER${NC}"
    echo -e "Manual command:"
    echo -e "  ${GREEN}./pumba/pause_process.sh $LEADER 30s${NC}"
    
    pause_for_user

    echo -e "\n${CYAN}Freezing leader $LEADER for 30s...${NC}"
    ./pumba/pause_process.sh "$LEADER" 30s
    
    echo -e "\n${GREEN}Experiment finished.${NC}"
    echo -e "Check cluster logs to see the watchdog engagement:"
    echo -e "  ${CYAN}docker compose -f $COMPOSE_FILE logs -f $LEADER${NC}"
    read -p "Press [Enter] to return to menu..."
}

while true; do
    show_header
    echo -e "Choose a chaos experiment to execute:"
    echo -e "  1) ${CYAN}Slow DCS (etcd latency)${NC}"
    echo -e "  2) ${CYAN}Replication Link Packet Loss${NC}"
    echo -e "  3) ${CYAN}Process Freeze (Watchdog Test)${NC}"
    echo -e "  4) Exit"
    echo ""
    read -p "Selection [1-4]: " choice
    case "$choice" in
        1) run_slow_dcs ;;
        2) run_loss ;;
        3) run_freeze ;;
        4) exit 0 ;;
        *) echo -e "${RED}Invalid choice!${NC}"; sleep 1 ;;
    esac
done
