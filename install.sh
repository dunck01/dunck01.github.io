#!/usr/bin/env bash
set -euo pipefail

echo "=============================================="
echo "  DunckOps Platform - Instalador de Producao"
echo "=============================================="
echo ""

REGISTRY_OWNER="${REGISTRY_OWNER:-dunck01}"
BASE_URL="${DUNCKOPS_BASE_URL:-https://get.duncktech.com}"

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

if ! command -v docker &> /dev/null; then
    echo "ERRO: Docker nao esta instalado."
    echo "Instale o Docker: https://docs.docker.com/engine/install/"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "ERRO: Docker Compose v2 nao esta instalado."
    echo "Instale o Docker Compose: https://docs.docker.com/compose/install/"
    exit 1
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
    if [ -f "$filename" ]; then
        echo "  $filename (ja existe localmente)"
        continue
    fi

    if command -v curl &> /dev/null; then
        curl -fsSL "${BASE_URL}/${filename}" -o "$filename" || true
    elif command -v wget &> /dev/null; then
        wget -q "${BASE_URL}/${filename}" -O "$filename" || true
    fi

    if [ -f "$filename" ]; then
        echo "  $filename (baixado)"
    else
        echo "  $filename (nao disponivel, pulando)"
    fi
done

if [ -f "$ENV_EXAMPLE" ]; then
    echo "  $ENV_EXAMPLE (ja existe localmente)"
else
    if command -v curl &> /dev/null; then
        curl -fsSL "${BASE_URL}/${REMOTE_ENV_EXAMPLE}" -o "$ENV_EXAMPLE" || true
    elif command -v wget &> /dev/null; then
        wget -q "${BASE_URL}/${REMOTE_ENV_EXAMPLE}" -O "$ENV_EXAMPLE" || true
    fi

    if [ -f "$ENV_EXAMPLE" ]; then
        echo "  $ENV_EXAMPLE (baixado)"
    else
        echo "  $ENV_EXAMPLE (nao disponivel, pulando)"
    fi
fi

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

echo ""
echo "[4/5] Baixando imagens Docker..."

COMPOSE_ARGS="-f $COMPOSE_FILE"

if [ -f "$DOCKER_OPS_FILE" ]; then
    docker compose $COMPOSE_ARGS -f "$DOCKER_OPS_FILE" pull
else
    docker compose $COMPOSE_ARGS pull
fi

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
echo "  - API:    http://localhost:${API_PORT:-9000}"
echo "  - Web:    http://localhost:${WEB_PORT:-5173}"
echo ""
echo "Comandos uteis:"
echo "  Status   : docker compose $COMPOSE_ARGS ps"
echo "  Logs     : docker compose $COMPOSE_ARGS logs -f"
echo "  Atualizar: ./scripts/update.sh"
echo "  Rollback : ./scripts/rollback.sh <versao>"
echo ""
echo "Proximos passos:"
echo "  1. Acesse http://localhost:${WEB_PORT:-5173}"
echo "  2. Faca login com suas credenciais comerciais"
echo "  3. Configure seus bancos de dados"
echo ""
