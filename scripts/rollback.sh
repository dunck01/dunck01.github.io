#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/rollback.sh <version>"
    echo "Example: ./scripts/rollback.sh v1.0.0"
    exit 1
fi

echo "=== DunckOps Platform Rollback to $VERSION ==="
echo ""

if [ ! -f .env ]; then
    echo "ERROR: .env file not found."
    exit 1
fi

COMPOSE_FILE="docker-compose.prod.yml"
DOCKER_OPS_FILE="docker-compose.docker-ops.prod.yml"

COMPOSE_ARGS="-f $COMPOSE_FILE"
if [ -f "$DOCKER_OPS_FILE" ]; then
    COMPOSE_ARGS="$COMPOSE_ARGS -f $DOCKER_OPS_FILE"
fi

echo "Stopping current services..."
docker compose $COMPOSE_ARGS down

echo "Setting version to $VERSION..."
export DUNCKOPS_VERSION="$VERSION"

echo "Starting services with $VERSION..."
docker compose $COMPOSE_ARGS up -d

echo ""
echo "=== Rollback Complete ==="
echo ""
echo "Check status: docker compose $COMPOSE_ARGS ps"
echo "View logs:    docker compose $COMPOSE_ARGS logs -f"
echo ""
