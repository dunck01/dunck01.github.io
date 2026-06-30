#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

echo "=== DunckOps Platform Update ==="
echo ""

if [ ! -f .env ]; then
    echo "ERROR: .env file not found."
    echo "Run install.sh first."
    exit 1
fi

COMPOSE_FILE="docker-compose.prod.yml"
DOCKER_OPS_FILE="docker-compose.docker-ops.prod.yml"
BASE_URL="${DUNCKOPS_BASE_URL:-https://get.dunckops.com}"

COMPOSE_ARGS="-f $COMPOSE_FILE"
if [ -f "$DOCKER_OPS_FILE" ]; then
    COMPOSE_ARGS="$COMPOSE_ARGS -f $DOCKER_OPS_FILE"
fi

pull_managed_images() {
    docker compose $COMPOSE_ARGS pull

    if [ -f "$DOCKER_OPS_FILE" ]; then
        docker compose $COMPOSE_ARGS --profile tools pull backup-runtime
    fi
}

build_postgres_images() {
    local dockerfile="infra/docker/postgres/Dockerfile"
    local context="infra/docker/postgres"
    local majors="${POSTGRES_IMAGE_MAJORS:-15 16 17}"

    if [ ! -f "$dockerfile" ]; then
        echo "ERROR: custom PostgreSQL Dockerfile not found at $dockerfile."
        exit 1
    fi

    for major in $majors; do
        echo "  - Building dunckops-postgres:${major}-alpine..."
        docker build \
            -t "dunckops-postgres:${major}-alpine" \
            --build-arg "POSTGRES_MAJOR=${major}" \
            -f "$dockerfile" \
            "$context"
    done
}

download_file() {
    local remote_path="$1"
    local output_path="$2"

    mkdir -p "$(dirname "$output_path")"

    if command -v curl &> /dev/null; then
        curl -fsSL "${BASE_URL}/${remote_path}" -o "$output_path"
    elif command -v wget &> /dev/null; then
        wget -q "${BASE_URL}/${remote_path}" -O "$output_path"
    else
        echo "ERROR: curl or wget is required."
        exit 1
    fi
}

download_postgres_build_assets() {
    download_file "infra/docker/postgres/Dockerfile" "infra/docker/postgres/Dockerfile"
    download_file "infra/docker/postgres/wal-push-wrapper.sh" "infra/docker/postgres/wal-push-wrapper.sh"
    chmod +x "infra/docker/postgres/wal-push-wrapper.sh"
}

echo "Pulling latest images..."
pull_managed_images

echo ""
echo "Building custom PostgreSQL images..."
download_postgres_build_assets
build_postgres_images

echo "Restarting services..."
docker compose $COMPOSE_ARGS down
docker compose $COMPOSE_ARGS up -d

echo ""
echo "=== Update Complete ==="
echo ""
echo "Check status: docker compose $COMPOSE_ARGS ps"
echo "View logs:    docker compose $COMPOSE_ARGS logs -f"
echo ""
