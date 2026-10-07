#!/usr/bin/env bash
set +x
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../docker-compose.prod.yml" ]; then
    PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
else
    PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
fi

cd "$PROJECT_DIR"

echo "=== DunckOps Platform Update ==="
echo ""

if [ ! -f .env ]; then
    echo "ERROR: .env file not found."
    echo "Run install.sh first."
    exit 1
fi

COMPOSE_FILE="docker-compose.prod.yml"
# Updates use persisted installer ports, not unrelated shell overrides.
for port_key in WEB_PORT API_PORT LOCAL_MINIO_API_PORT LOCAL_MINIO_CONSOLE_PORT; do
    unset "$port_key"
done
DOCKER_OPS_FILE="docker-compose.docker-ops.prod.yml"
BASE_URL="${DUNCKOPS_BASE_URL:-https://get.dunckops.com}"

COMPOSE_ARGS="-f $COMPOSE_FILE"
if [ -f "$DOCKER_OPS_FILE" ]; then
    COMPOSE_ARGS="$COMPOSE_ARGS -f $DOCKER_OPS_FILE"
fi

pull_managed_images() {
    local config timeout runtime_overrides snapshot_overrides engine image key value multi sql restore_pull service override_key
    config="$(docker compose $COMPOSE_ARGS config --format json)"
    local release_version
    release_version="$(docker compose $COMPOSE_ARGS config --environment | sed -n 's/^DUNCKOPS_VERSION=//p')"
    if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ERRO: DUNCKOPS_VERSION exige release X.Y.Z publicada; nunca latest. Nenhum pull ou restart executado."
        return 1
    fi
    for key in PHYSICAL_SNAPSHOTS_ENABLED MULTI_ENGINE_OPERATIONS_ENABLED SQLSERVER_OPERATIONS_UNVERIFIED_OPT_IN; do
        value="$(printf '%s\n' "$config" | sed -n "s/.*\"$key\": \"\([^\"]*\)\".*/\1/p" | sort -u)"
        if [[ "$value" != true && "$value" != false ]]; then
            echo "ERRO: $key deve ser true ou false, igual na API e agent."
            return 1
        fi
        case "$key" in
            MULTI_ENGINE_OPERATIONS_ENABLED) multi="$value" ;;
            SQLSERVER_OPERATIONS_UNVERIFIED_OPT_IN) sql="$value" ;;
        esac
    done
    timeout="$(printf '%s\n' "$config" | sed -n 's/.*"SQLSERVER_OPERATIONS_TIMEOUT_SECONDS": "\([^"]*\)".*/\1/p' | sort -u)"
    if [[ ! "$timeout" =~ ^[1-9][0-9]{1,3}$ ]] || (( timeout < 60 || timeout > 7200 )); then
        echo "ERRO: SQLSERVER_OPERATIONS_TIMEOUT_SECONDS deve ser inteiro 60..7200, igual na API e agent."
        return 1
    fi
    image="$(printf '%s\n' "$config" | sed -n 's/.*"SQLSERVER_OPERATIONS_RUNTIME_IMAGE": "\([^"]*\)".*/\1/p' | sort -u)"
    if [ -n "$image" ] && [[ ! "$image" =~ ^sha256:[a-f0-9]{64}$ ]]; then
        echo "ERRO: SQLSERVER_OPERATIONS_RUNTIME_IMAGE aceita somente ID sha256 imutavel aprovado manualmente, nunca tag."
        return 1
    fi
    runtime_overrides="$(docker compose $COMPOSE_ARGS config --environment | sed -n '/^MULTI_ENGINE_RESTORE_SERVER_IMAGES_PULL=/p; /^MYSQL_OPERATIONS_RUNTIME_IMAGE=/p; /^MARIADB_OPERATIONS_RUNTIME_IMAGE=/p; /^MONGO_OPERATIONS_RUNTIME_IMAGE=/p; /^SQLSERVER_OPERATIONS_CLIENT_TOOLS_IMAGE=/p; /^MYSQL_RESTORE_SERVER_IMAGE=/p; /^MARIADB_RESTORE_SERVER_IMAGE=/p')"
    restore_pull="$(printf '%s\n' "$runtime_overrides" | sed -n 's/^MULTI_ENGINE_RESTORE_SERVER_IMAGES_PULL=//p')"
    restore_pull="${restore_pull:-false}"
    if [[ "$restore_pull" != true && "$restore_pull" != false ]]; then
        echo "ERRO: MULTI_ENGINE_RESTORE_SERVER_IMAGES_PULL deve ser true ou false."
        return 1
    fi
    timeout="$(printf '%s\n' "$config" | sed -n 's/.*"PHYSICAL_SNAPSHOT_TIMEOUT_MINUTES": "\([^"]*\)".*/\1/p' | sort -u)"
    if [[ ! "$timeout" =~ ^([1-9]|[1-9][0-9]|1[01][0-9]|120)$ ]]; then
        echo "ERRO: PHYSICAL_SNAPSHOT_TIMEOUT_MINUTES deve ser inteiro 1..120, igual na API e agent."
        return 1
    fi
    if printf '%s\n' "$config" | grep -Eiq '"PHYSICAL_SNAPSHOTS_ENABLED": "true"'; then
        if [ ! -f "$DOCKER_OPS_FILE" ]; then
            echo "ERRO: runtimes experimentais indisponiveis. Verifique REGISTRY_OWNER/DUNCKOPS_VERSION e a publicacao de ambas as imagens; ou desative PHYSICAL_SNAPSHOTS_ENABLED. Servicos atuais nao foram interrompidos."
            return 1
        fi
        # Compose parses/interpolates overrides as data, including operator .env values.
        snapshot_overrides="$(docker compose $COMPOSE_ARGS config --environment | sed -n '/^MYSQL_SNAPSHOT_RUNTIME_IMAGE=/p; /^MARIADB_SNAPSHOT_RUNTIME_IMAGE=/p')"
        for engine in mysql mariadb; do
            image="$(printf '%s\n' "$snapshot_overrides" | sed -n "s/^${engine^^}_SNAPSHOT_RUNTIME_IMAGE=//p")"
            if [ -n "$image" ] && docker image inspect -- "$image" > /dev/null 2>&1; then
                echo "Usando imagem local explicitamente configurada para ${engine}-snapshot-runtime."
                continue
            fi
            if ! COMPOSE_PROFILES= docker compose $COMPOSE_ARGS --profile tools pull "${engine}-snapshot-runtime"; then
                echo "ERRO: ${engine}-snapshot-runtime indisponivel. Verifique REGISTRY_OWNER/DUNCKOPS_VERSION e a publicacao da imagem; ou configure o override com uma imagem instalada localmente; ou desative PHYSICAL_SNAPSHOTS_ENABLED. Servicos atuais nao foram interrompidos."
                return 1
            fi
        done
    fi
    if [ "$multi" = true ]; then
        if [ ! -f "$DOCKER_OPS_FILE" ]; then
            echo "ERRO: Compose de ferramentas ausente; servicos atuais nao foram interrompidos."
            return 1
        fi
        # Resolve explicit helper overrides locally; never send local tags/IDs to a registry.
        image="$(docker compose $COMPOSE_ARGS config --environment | sed -n 's/^ENGINE_ARTIFACTS_RUNTIME_IMAGE=//p')"
        if [ -n "$image" ]; then
            docker image inspect -- "$image" > /dev/null 2>&1 || {
                echo "ERRO: ENGINE_ARTIFACTS_RUNTIME_IMAGE deve estar instalada localmente; ou deixe vazio para imagem publicada."
                return 1
            }
        else
            release_version="$(docker compose $COMPOSE_ARGS config --environment | sed -n 's/^DUNCKOPS_VERSION=//p')"
            if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "ERRO: runtime de artefatos exige DUNCKOPS_VERSION fixada em release X.Y.Z, nunca latest."
                return 1
            fi
            COMPOSE_PROFILES= docker compose $COMPOSE_ARGS --profile tools pull engine-artifacts-runtime || return 1
        fi
        copy_version="$(docker compose $COMPOSE_ARGS config --environment | sed -n 's/^ENGINE_COPY_RUNTIME_VERSION=//p')"
        copy_version="${copy_version:-$(docker compose $COMPOSE_ARGS config --environment | sed -n 's/^DUNCKOPS_VERSION=//p')}"
        if [[ ! "$copy_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "ERRO: runtimes de copia exigem ENGINE_COPY_RUNTIME_VERSION / DUNCKOPS_VERSION X.Y.Z."
            return 1
        fi
        for variant in mysql-8.0 mysql-8.4 mariadb-10.11 mariadb-11.4; do
            service="engine-copy-${variant//./-}"
            image="$(docker compose $COMPOSE_ARGS --profile tools config --images "$service")" || return 1
            if docker image inspect -- "$image" > /dev/null 2>&1; then
                continue
            fi
            if [[ "$image" == ghcr.io/* ]]; then
                COMPOSE_PROFILES= docker compose $COMPOSE_ARGS --profile tools pull "$service" || return 1
            else
                echo "ERRO: runtime de copia local/custom nao instalado: $image. Construa-o ou configure prefixo GHCR publicado."
                return 1
            fi
        done
        for engine in mysql mariadb mongo sqlserver; do
            [ "$engine" != sqlserver ] || [ "$sql" = true ] || continue
            service="${engine}-operations-runtime"
            override_key="${engine^^}_OPERATIONS_RUNTIME_IMAGE"
            [ "$engine" != sqlserver ] || override_key=SQLSERVER_OPERATIONS_CLIENT_TOOLS_IMAGE
            image="$(printf '%s\n' "$runtime_overrides" | sed -n "s/^${override_key}=//p")"
            if [ -n "$image" ]; then
                if ! docker image inspect -- "$image" > /dev/null 2>&1; then
                    echo "ERRO: $override_key deve referenciar imagem ja instalada localmente; instale/aprove manualmente ou deixe vazio para download publicado."
                    return 1
                fi
                continue
            fi
            COMPOSE_PROFILES= docker compose $COMPOSE_ARGS --profile tools pull "$service" || return 1
        done
        if [ "$restore_pull" = true ]; then
            for engine in mysql mariadb; do
                image="$(printf '%s\n' "$config" | sed -n "s/.*\"${engine^^}_RESTORE_SERVER_IMAGE\": \"\([^\"]*\)\".*/\1/p" | sort -u)"
                docker image inspect -- "$image" > /dev/null 2>&1 && continue
                COMPOSE_PROFILES= docker compose $COMPOSE_ARGS --profile tools pull "${engine}-restore-server" || return 1
            done
            for image in mysql:8.0 mysql:8.4 mariadb:10.11 mariadb:11.4 mongo:6.0 mongo:7.0 mongo:8.0; do
                docker image inspect -- "$image" > /dev/null 2>&1 && continue
                docker pull "$image" || return 1
            done
        fi
    fi
    # Ignore inherited tools profiles: experimental images require explicit opt-in.
    COMPOSE_PROFILES= docker compose $COMPOSE_ARGS pull

    if [ -f "$DOCKER_OPS_FILE" ]; then
        docker compose $COMPOSE_ARGS --profile tools pull backup-runtime
    fi
}

build_postgres_images() {
    local dockerfile="infra/docker/postgres/Dockerfile"
    local context="infra/docker/postgres"
    local majors="${POSTGRES_IMAGE_MAJORS:-15 16 17 18}"

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

echo "Creating pre-update backup..."
command -v curl >/dev/null 2>&1 || { echo "ERRO: instale curl para validar prontidao local; servicos nao foram interrompidos."; exit 1; }
# Published installations may not yet contain this helper. Fetch before downtime.
download_file "scripts/install-ports.sh" "scripts/install-ports.sh.new"
mv "scripts/install-ports.sh.new" "scripts/install-ports.sh"
source "scripts/install-ports.sh"
port_environment="$(docker compose $COMPOSE_ARGS config --environment)"
for port_key in WEB_PORT API_PORT LOCAL_MINIO_API_PORT LOCAL_MINIO_CONSOLE_PORT; do
    port_value="$(printf '%s\n' "$port_environment" | sed -n "s/^${port_key}=//p")"
    case "$port_key" in
        WEB_PORT) port_value="${port_value:-9000}" ;;
        API_PORT) port_value="${port_value:-9100}" ;;
        LOCAL_MINIO_API_PORT) port_value="${port_value:-9002}" ;;
        LOCAL_MINIO_CONSOLE_PORT) port_value="${port_value:-9001}" ;;
    esac
    parse_install_binding "$port_value"
    export "$port_key=$port_value"
done
configure_install_minio_endpoint "$port_environment"
"$SCRIPT_DIR/backup-before-update.sh"

echo "Downloading current Compose files..."
download_file "$COMPOSE_FILE" "$COMPOSE_FILE.new"
download_file "$DOCKER_OPS_FILE" "$DOCKER_OPS_FILE.new"
mv "$COMPOSE_FILE.new" "$COMPOSE_FILE"
mv "$DOCKER_OPS_FILE.new" "$DOCKER_OPS_FILE"

echo "Pulling pinned release images..."
pull_managed_images

echo "Restarting services..."
docker compose $COMPOSE_ARGS down
COMPOSE_PROFILES= docker compose $COMPOSE_ARGS up -d
wait_install_ready

download_file "scripts/update.sh" "scripts/update.sh.new"
download_file "scripts/rollback.sh" "scripts/rollback.sh.new"
download_file "scripts/backup-before-update.sh" "scripts/backup-before-update.sh.new"
for script in update.sh rollback.sh backup-before-update.sh; do
    mv "scripts/$script.new" "scripts/$script"
    chmod +x "scripts/$script"
done

echo ""
echo "=== Update Complete ==="
echo ""
echo "Check status: docker compose $COMPOSE_ARGS ps"
echo "View logs:    docker compose $COMPOSE_ARGS logs -f"
echo ""
