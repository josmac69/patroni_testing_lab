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
    echo -e "${BLUE}${BOLD}                    PATRONI PGBACKREST DEMO UTILITY                    ${NC}"
    echo -e "${BLUE}${BOLD}========================================================================${NC}"
}

pause_for_user() {
    echo ""
    read -p "Press [Enter] to run the step..."
}

configure_archiving() {
    show_header
    echo -e "${YELLOW}${BOLD}Step 1: Configure Dynamic Archiving in Patroni DCS${NC}"
    echo -e "This step tells Patroni to manage PostgreSQL's archive_mode and archive_command."
    echo ""
    echo -e "Under normal conditions, you would execute these manual commands:"
    echo -e "  ${GREEN}docker compose exec patroni1 patronictl -c /tmp/patroni.yml edit-config --force \\"
    echo -e "    -s \"postgresql.parameters.archive_mode=on\" \\"
    echo -e "    -s \"postgresql.parameters.archive_command=pgbackrest --stanza=lab archive-push %p\"${NC}"
    
    pause_for_user

    echo -e "\n${CYAN}Applying configuration...${NC}"
    docker compose -f "$COMPOSE_FILE" exec patroni1 patronictl -c /tmp/patroni.yml edit-config --force \
      -s "postgresql.parameters.archive_mode=on" \
      -s "postgresql.parameters.archive_command=pgbackrest --stanza=lab archive-push %p"
    
    echo -e "\n${GREEN}Configuration updated successfully.${NC}"
    read -p "Press [Enter] to return to menu..."
}

restart_cluster() {
    show_header
    echo -e "${YELLOW}${BOLD}Step 2: Restart Cluster Containers${NC}"
    echo -e "PostgreSQL requires a restart to enable archive_mode."
    echo ""
    echo -e "Manual command:"
    echo -e "  ${GREEN}docker compose restart patroni1 patroni2 patroni3${NC}"
    
    pause_for_user

    echo -e "\n${CYAN}Restarting Patroni containers...${NC}"
    docker compose -f "$COMPOSE_FILE" restart patroni1 patroni2 patroni3
    
    echo -e "\n${GREEN}Containers restarted successfully.${NC}"
    read -p "Press [Enter] to return to menu..."
}

create_stanza_backup() {
    show_header
    echo -e "${YELLOW}${BOLD}Step 3: Create pgBackRest Stanza & Take Full Backup${NC}"
    echo -e "We initialize the backup metadata repository (stanza) and trigger a full physical backup."
    echo ""
    echo -e "Manual commands:"
    echo -e "  ${GREEN}docker compose exec patroni1 pgbackrest --stanza=lab stanza-create${NC}"
    echo -e "  ${GREEN}docker compose exec patroni1 pgbackrest --stanza=lab --type=full backup${NC}"
    echo -e "  ${GREEN}docker compose exec patroni1 pgbackrest --stanza=lab info${NC}"
    
    pause_for_user

    echo -e "\n${CYAN}Creating pgBackRest stanza...${NC}"
    docker compose -f "$COMPOSE_FILE" exec patroni1 pgbackrest --stanza=lab stanza-create
    
    echo -e "\n${CYAN}Taking full backup (may take a few seconds)...${NC}"
    docker compose -f "$COMPOSE_FILE" exec patroni1 pgbackrest --stanza=lab --type=full backup
    
    echo -e "\n${CYAN}Fetching backup info...${NC}"
    docker compose -f "$COMPOSE_FILE" exec patroni1 pgbackrest --stanza=lab info
    
    echo -e "\n${GREEN}Stanza and backup created successfully.${NC}"
    read -p "Press [Enter] to return to menu..."
}

reinit_replica() {
    show_header
    echo -e "${YELLOW}${BOLD}Step 4: Reinitialize replica from backup repository${NC}"
    echo -e "We corrupt or reset a standby and watch Patroni rebuild it from pgBackRest instead of overloading the primary."
    echo ""
    echo -e "Manual command:"
    echo -e "  ${GREEN}make -C ../enhanced_3_nodes scenario-reinit-replica${NC}"
    
    pause_for_user

    echo -e "\n${CYAN}Executing replica reinitialization...${NC}"
    # Run the make target inside enhanced_3_nodes
    (cd ../enhanced_3_nodes && make scenario-reinit-replica)
    
    echo -e "\n${CYAN}Verifying logs of patroni2 for pgBackRest restore calls...${NC}"
    # Wait a bit for restore logs to show up
    sleep 3
    docker compose -f "$COMPOSE_FILE" logs patroni2 | grep -i pgbackrest || echo "No pgbackrest log statements found yet. Check logs manually via: docker compose logs patroni2"
    
    echo -e "\n${GREEN}Experiment finished.${NC}"
    read -p "Press [Enter] to return to menu..."
}

while true; do
    show_header
    echo -e "Choose an action to perform:"
    echo -e "  1) ${CYAN}Configure Dynamic Archiving in Patroni${NC}"
    echo -e "  2) ${CYAN}Restart cluster containers (activate archive_mode)${NC}"
    echo -e "  3) ${CYAN}Create pgBackRest Stanza & Take Backup${NC}"
    echo -e "  4) ${CYAN}Reinitialize Replica from pgBackRest Repository${NC}"
    echo -e "  5) Exit"
    echo ""
    read -p "Selection [1-5]: " choice
    case "$choice" in
        1) configure_archiving ;;
        2) restart_cluster ;;
        3) create_stanza_backup ;;
        4) reinit_replica ;;
        5) exit 0 ;;
        *) echo -e "${RED}Invalid choice!${NC}"; sleep 1 ;;
    esac
done
