#!/usr/bin/env bash
# scripts/run_ingestion.sh: Run the Patroni replication testing ingestion client.
# Works in both docker-container mode and local-host mode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default connection settings for running from host (connecting to HAProxy mapped port 5000)
export DB_HOST=${DB_HOST:-"localhost"}
export DB_PORT=${DB_PORT:-"5000"}
export DB_USER=${DB_USER:-"postgres"}
export DB_PASSWORD=${DB_PASSWORD:-"postgres_password"}
export DB_NAME=${DB_NAME:-"postgres"}

usage() {
    echo "Usage: $0 [docker | local | help]"
    echo ""
    echo "Modes:"
    echo "  docker    Run the ingestion script inside a temporary Docker container"
    echo "            connecting to the HAProxy router in the patroni-net network."
    echo "  local     Run the ingestion script on the host machine."
    echo "            Requires python3 and sets up a local virtual environment."
    echo "  help      Show this help message."
    echo ""
    echo "Environment Variables (for local mode):"
    echo "  DB_HOST      Database host (default: localhost)"
    echo "  DB_PORT      Database port (default: 5000)"
    echo "  DB_USER      Database user (default: postgres)"
    echo "  DB_PASSWORD  Database password (default: postgres_password)"
    echo "  DB_NAME      Database name (default: postgres)"
}

run_docker() {
    echo "Running ingestion client in Docker container..."
    cd "${PROJECT_DIR}"
    docker compose run --rm client
}

run_local() {
    echo "Running ingestion client locally on host..."
    cd "${PROJECT_DIR}"
    
    # Check python3
    if ! command -v python3 &>/dev/null; then
        echo "Error: python3 is not installed on the host." >&2
        exit 1
    fi

    # Create virtual environment if it doesn't exist
    if [ ! -d ".venv" ]; then
        echo "Creating virtual environment in .venv..."
        python3 -m venv .venv
    fi

    # Activate virtual environment
    source .venv/bin/activate

    # Install psycopg2-binary
    echo "Installing required psycopg2-binary package..."
    pip install -q psycopg2-binary

    echo "Starting ingestion client connecting to postgres://${DB_USER}:****@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    python3 scripts/ingest.py
}

MODE=${1:-"docker"}

case "${MODE}" in
    docker)
        run_docker
        ;;
    local)
        run_local
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Error: Unknown mode '${MODE}'" >&2
        usage
        exit 1
        ;;
esac
