#!/usr/bin/env bash
set -euo pipefail

echo "=============================================="
echo "  DunckOps Platform - Instalador de Producao"
echo "=============================================="
echo ""

REGISTRY_OWNER="${REGISTRY_OWNER:-dunck01}"
BASE_URL="${DUNCKOPS_BASE_URL:-https://get.dunckops.com}"

prompt_input() {
    local prompt_text="$1"
    local result_var="$2"
    local secret="${3:-false}"
    local value=""

    if [ -r /dev/tty ]; then
        if [ "$secret" = "true" ]; then
            printf '%s' "$prompt_text" > /dev/tty
            if ! IFS= read -r -s value < /dev/tty; then
                return 1
            fi
            printf '\n' > /dev/tty
        else
            printf '%s' "$prompt_text" > /dev/tty
            if ! IFS= read -r value < /dev/tty; then
                return 1
            fi
        fi
    else
        if [ "$secret" = "true" ]; then
            printf '%s' "$prompt_text"
            if ! IFS= read -r -s value; then
                return 1
            fi
            printf '\n'
        else
            printf '%s' "$prompt_text"
            if ! IFS= read -r value; then
                return 1
            fi
        fi
    fi

    printf -v "$result_var" '%s' "$value"
}

random_secret() {
    if command -v openssl &> /dev/null; then
        openssl rand -hex 32
    else
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64
    fi
}

set_env_value() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        echo "${key}=${value}" >> .env
    fi
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
        echo "ERRO: curl ou wget nao esta instalado."
        exit 1
    fi
}

download_postgres_build_assets() {
    download_file "infra/docker/postgres/Dockerfile" "infra/docker/postgres/Dockerfile"
    echo "  infra/docker/postgres/Dockerfile (atualizado)"

    download_file "infra/docker/postgres/wal-push-wrapper.sh" "infra/docker/postgres/wal-push-wrapper.sh"
    chmod +x "infra/docker/postgres/wal-push-wrapper.sh"
    echo "  infra/docker/postgres/wal-push-wrapper.sh (atualizado)"
}

download_support_scripts() {
    download_file "scripts/update.sh" "scripts/update.sh"
    chmod +x "scripts/update.sh"
    echo "  scripts/update.sh (atualizado)"

    download_file "scripts/rollback.sh" "scripts/rollback.sh"
    chmod +x "scripts/rollback.sh"
    echo "  scripts/rollback.sh (atualizado)"
}

build_postgres_images() {
    local dockerfile="infra/docker/postgres/Dockerfile"
    local context="infra/docker/postgres"
    local majors="${POSTGRES_IMAGE_MAJORS:-15 16 17}"

    if [ ! -f "$dockerfile" ]; then
        echo "ERRO: Dockerfile do PostgreSQL customizado nao encontrado em $dockerfile."
        exit 1
    fi

    for major in $majors; do
        echo "  - Construindo dunckops-postgres:${major}-alpine..."
        docker build \
            -t "dunckops-postgres:${major}-alpine" \
            --build-arg "POSTGRES_MAJOR=${major}" \
            -f "$dockerfile" \
            "$context"
    done
}

if ! command -v docker &> /dev/null; then
    echo "Docker nao encontrado. Instalando..."
    echo ""
    curl -fsSL https://get.docker.com | sh
    echo ""
    echo "Docker instalado com sucesso."
fi

if ! docker compose version &> /dev/null; then
    echo "ERRO: Docker Compose v2 nao esta disponivel."
    echo "O script oficial do Docker deveria ter instalado o Compose."
    echo "Instale manualmente: https://docs.docker.com/compose/install/"
    exit 1
fi

if [ -z "${DUNCKOPS_LICENSE_KEY:-}" ] && [ -f .env ]; then
    existing_key="$(grep '^DUNCKOPS_LICENSE_KEY=' .env | cut -d'=' -f2-)"
    if [ -n "$existing_key" ]; then
        DUNCKOPS_LICENSE_KEY="$existing_key"
        echo "License key encontrada no .env existente."
    fi
fi

if [ -z "${DUNCKOPS_LICENSE_KEY:-}" ]; then
    printf 'Digite sua chave de licenca DunckOps:\n'
    printf '  (Obtenha sua chave em https://dunckops.com/dashboard)\n'
    if ! prompt_input "> " DUNCKOPS_LICENSE_KEY true; then
        echo "ERRO: Nao foi possivel ler a chave de licenca."
        exit 1
    fi

    if [ -z "$DUNCKOPS_LICENSE_KEY" ]; then
        echo "ERRO: Chave de licenca e obrigatoria."
        exit 1
    fi
fi

export DUNCKOPS_LICENSE_KEY

echo ""
echo "[1/5] Preparando instalacao..."
echo "Usando imagens publicas em ghcr.io/${REGISTRY_OWNER}."

echo ""
echo "[2/5] Baixando arquivos de configuracao..."

COMPOSE_FILE="docker-compose.prod.yml"
DOCKER_OPS_FILE="docker-compose.docker-ops.prod.yml"
ENV_EXAMPLE=".env.production.example"
REMOTE_ENV_EXAMPLE="env.production.example"

for filename in "$COMPOSE_FILE" "$DOCKER_OPS_FILE"; do
    download_file "$filename" "$filename"
    echo "  $filename (atualizado)"
done

download_file "$REMOTE_ENV_EXAMPLE" "$ENV_EXAMPLE"
echo "  $ENV_EXAMPLE (atualizado)"

download_postgres_build_assets
download_support_scripts

echo ""
echo "[3/5] Configurando variaveis de ambiente..."

if [ ! -f .env ]; then
    if [ -f .env.production.example ]; then
        cp .env.production.example .env
    else
        touch .env
    fi

    echo "Gerando secrets locais no arquivo .env:"
    echo ""

    db_password="$(random_secret)"
    minio_access_key="dunckops$(random_secret | cut -c 1-16)"
    minio_secret_key="$(random_secret)"
    enc_key="$(random_secret)"
    jwt_key="$(random_secret)"
    agent_key="$(random_secret)"

    echo ""
    echo "Aplicando valores no .env..."

    set_env_value "DUNCKOPS_DB_PASSWORD" "$db_password"
    set_env_value "LOCAL_MINIO_ACCESS_KEY" "$minio_access_key"
    set_env_value "LOCAL_MINIO_SECRET_KEY" "$minio_secret_key"
    set_env_value "Encryption__MasterKey" "$enc_key"
    set_env_value "Jwt__Key" "$jwt_key"
    set_env_value "DOCKER_AGENT_KEY" "$agent_key"
    set_env_value "DUNCKOPS_LICENSE_KEY" "$DUNCKOPS_LICENSE_KEY"

    echo ""
    echo ".env configurado. Verifique o arquivo antes de continuar."
else
    echo "Arquivo .env ja existe, mantendo configuracao atual."
fi

if ! grep -q "^WEB_PORT=" .env || grep -q "^WEB_PORT=5173$" .env; then
    set_env_value "WEB_PORT" "9000"
fi

if ! grep -q "^API_PORT=" .env || grep -q "^API_PORT=9000$" .env; then
    set_env_value "API_PORT" "9100"
fi

if ! grep -q "^CORS_ORIGINS=" .env || grep -q "^CORS_ORIGINS=http://localhost:5173$" .env; then
    set_env_value "CORS_ORIGINS" "http://localhost:9000"
fi

echo ""
echo "[4/5] Baixando imagens Docker..."

COMPOSE_ARGS="-f $COMPOSE_FILE"

if [ -f "$DOCKER_OPS_FILE" ]; then
    docker compose $COMPOSE_ARGS -f "$DOCKER_OPS_FILE" pull
else
    docker compose $COMPOSE_ARGS pull
fi

echo ""
echo "Construindo imagens customizadas do PostgreSQL..."
build_postgres_images

echo ""
echo "[5/5] Iniciando servicos..."

if [ -f "$DOCKER_OPS_FILE" ]; then
    docker compose $COMPOSE_ARGS -f "$DOCKER_OPS_FILE" up -d
else
    docker compose $COMPOSE_ARGS up -d
fi

echo ""
echo ""
echo "Verificando status..."

sleep 3
docker compose $COMPOSE_ARGS ps

echo ""
echo "=============================================="
echo "  Instalacao concluida!"
echo "=============================================="
echo ""
echo "Servicos:"
echo "  - Web:    http://localhost:${WEB_PORT:-9000}"
echo "  - API:    http://localhost:${API_PORT:-9100}"
echo ""
echo "Comandos uteis:"
echo "  Status   : docker compose $COMPOSE_ARGS ps"
echo "  Logs     : docker compose $COMPOSE_ARGS logs -f"
echo "  Atualizar: ./scripts/update.sh"
echo "  Rollback : ./scripts/rollback.sh <versao>"
echo ""
echo "Proximos passos:"
echo "  1. Acesse http://IP_DA_VPS:${WEB_PORT:-9000}/login"
echo "  2. Entre com sua conta DunckOps"
echo "  3. Depois use http://IP_DA_VPS:${WEB_PORT:-9000}/dashboard"
echo ""
