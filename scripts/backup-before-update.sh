#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../docker-compose.prod.yml" ]; then
    PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
else
    PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
fi

cd "$PROJECT_DIR"

echo "=== DunckOps Platform Pre-Update Backup ==="
echo ""

BACKUP_DIR="./backups/pre-update-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

COMPOSE_FILE="docker-compose.prod.yml"
DOCKER_OPS_FILE="docker-compose.docker-ops.prod.yml"

COMPOSE_ARGS="-f $COMPOSE_FILE"
if [ -f "$DOCKER_OPS_FILE" ]; then
    COMPOSE_ARGS="$COMPOSE_ARGS -f $DOCKER_OPS_FILE"
fi

echo "Backing up .env..."
if [ -f .env ]; then
    cp .env "$BACKUP_DIR/.env.backup"
    echo "Env backup: $BACKUP_DIR/.env.backup"
fi

echo "Backing up docker volumes..."
docker volume inspect dunckops-local-backups >/dev/null
docker run --rm \
    -v dunckops-local-backups:/source:ro \
    -v "$(pwd)/$BACKUP_DIR":/backup \
    alpine tar czf /backup/volumes.tar.gz -C /source .

echo "Backing up the control-plane PostgreSQL database..."
docker compose $COMPOSE_ARGS exec -T dunckops-db sh -c \
    'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner --no-acl' \
    > "$BACKUP_DIR/control-plane.dump"

if [ ! -s "$BACKUP_DIR/control-plane.dump" ]; then
    echo "ERROR: control-plane dump is empty."
    exit 1
fi

sha256sum "$BACKUP_DIR/control-plane.dump" "$BACKUP_DIR/volumes.tar.gz" > "$BACKUP_DIR/SHA256SUMS"
sha256sum --check "$BACKUP_DIR/SHA256SUMS"

echo ""
echo "=== Backup Complete ==="
echo ""
echo "Backup location: $BACKUP_DIR"
echo ""
echo "Contents:"
ls -lh "$BACKUP_DIR"
echo ""
echo "Control-plane database and local backup volume were captured with SHA-256 evidence."
echo "You can now safely run: cd $PROJECT_DIR && ./scripts/update.sh"
echo ""
