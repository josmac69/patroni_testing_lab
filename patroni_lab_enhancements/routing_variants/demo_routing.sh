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
    clear || true
    echo -e "${BLUE}${BOLD}========================================================================${NC}"
    echo -e "${BLUE}${BOLD}                     PATRONI ROUTING DEMO UTILITY                      ${NC}"
    echo -e "${BLUE}${BOLD}========================================================================${NC}"
}

pause_for_user() {
    echo ""
    read -p "Press [Enter] to run the step..."
}

test_libpq_multihost() {
    show_header
    echo -e "${YELLOW}${BOLD}Step 1: Test libpq multi-host connection routing${NC}"
    echo -e "This demonstrates client-side load balancing/routing by passing all host addresses"
    echo -e "in the connection string and specifying target_session_attrs=read-write."
    echo ""
    echo -e "Under normal conditions, you would execute this manual command:"
    echo -e "  ${GREEN}docker compose exec client psql \"host=patroni1,patroni2,patroni3 port=5432,5432,5432 target_session_attrs=read-write user=postgres dbname=postgres\" -c \"SELECT pg_is_in_recovery();\"${NC}"
    
    pause_for_user

    echo -e "\n${CYAN}Running the libpq multi-host command...${NC}"
    docker compose -f "$COMPOSE_FILE" exec -T client psql "host=patroni1,patroni2,patroni3 port=5432,5432,5432 target_session_attrs=read-write user=postgres dbname=postgres" -c "SELECT pg_is_in_recovery() AS is_replica, inet_server_addr() AS host_ip;" < /dev/null
    
    echo -e "\n${GREEN}Command executed successfully. Notice that target_session_attrs routed you directly to the writable primary node.${NC}"
    read -p "Press [Enter] to return to menu..."
}

explain_pgbouncer() {
    show_header
    echo -e "${YELLOW}${BOLD}Step 2: Explain PgBouncer Setup & Configuration${NC}"
    echo -e "To configure PgBouncer pooling in front of HAProxy, you need to append the compose snippet"
    echo -e "located at ${CYAN}pgbouncer/compose-snippet.yml${NC} to your ${CYAN}enhanced_3_nodes/docker-compose.yml${NC}."
    echo ""
    echo -e "How to manually spin it up once added:"
    echo -e "  ${GREEN}cd ../enhanced_3_nodes${NC}"
    echo -e "  ${GREEN}docker compose up -d pgbouncer${NC}"
    echo ""
    echo -e "How to run the load test harness through PgBouncer:"
    echo -e "  ${GREEN}docker compose exec client python rpo_rto_harness.py --duration 120${NC}"
    echo ""
    echo -e "Failover optimization settings are in ${CYAN}pgbouncer/pgbouncer.ini${NC}:"
    echo -e "  * ${BOLD}server_login_retry = 3${NC} (faster reconnect tries after failover)"
    echo -e "  * ${BOLD}query_wait_timeout = 120${NC} (how long queries queue during failover before failing)"
    echo ""
    read -p "Press [Enter] to return to menu..."
}

while true; do
    show_header
    echo -e "Choose an option to perform:"
    echo -e "  1) ${CYAN}Test libpq multi-host connection routing${NC}"
    echo -e "  2) ${CYAN}Explain PgBouncer Setup & Config${NC}"
    echo -e "  3) Exit"
    echo ""
    read -p "Selection [1-3]: " choice
    case "$choice" in
        1) test_libpq_multihost ;;
        2) explain_pgbouncer ;;
        3) exit 0 ;;
        *) echo -e "${RED}Invalid choice!${NC}"; sleep 1 ;;
    esac
done
