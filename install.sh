#!/usr/bin/env bash
set -euo pipefail

echo "=============================================="
echo "  DunckOps Platform - Instalador de Producao"
echo "=============================================="
echo ""

REGISTRY_OWNER="${REGISTRY_OWNER:-dunck01}"
GITHUB_USER="${DUNCKOPS_GITHUB_USERNAME:-$REGISTRY_OWNER}"
GITHUB_PAT="${DUNCKOPS_GITHUB_PAT:-}"
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
echo "[1/6] Autenticando no registry de containers..."

if [ -n "$GITHUB_PAT" ]; then
    echo "$GITHUB_PAT" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin
else
    printf 'Digite seu GitHub PAT para acessar o GHCR (ou Enter se ja estiver autenticado):\n'
    if prompt_input "> " GITHUB_PAT true; then
        if [ -n "$GITHUB_PAT" ]; then
            echo "$GITHUB_PAT" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin
        else
            echo "AVISO: nenhum PAT informado. Certifique-se de que o Docker ja esta autenticado no ghcr.io."
        fi
    else
        echo "AVISO: nao foi possivel ler o PAT. Certifique-se de que o Docker ja esta autenticado no ghcr.io."
    fi
fi

echo ""
echo "[2/6] Baixando arquivos de configuracao..."

COMPOSE_FILE="docker-compose.prod.yml"
DOCKER_OPS_FILE="docker-compose.docker-ops.prod.yml"
ENV_EXAMPLE=".env.production.example"

for filename in "$COMPOSE_FILE" "$DOCKER_OPS_FILE" "$ENV_EXAMPLE"; do
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

echo ""
echo "[3/6] Configurando variaveis de ambiente..."

if [ ! -f .env ]; then
    if [ -f .env.production.example ]; then
        cp .env.production.example .env
    else
        touch .env
    fi

    echo "Preencha os valores obrigatorios no arquivo .env:"
    echo ""

    if ! prompt_input "  ConnectionStrings__DefaultConnection [Host=...]: " db_conn; then
        echo "ERRO: Nao foi possivel ler ConnectionStrings__DefaultConnection."
        exit 1
    fi
    if ! prompt_input "  Encryption__MasterKey (32+ caracteres)  : " enc_key true; then
        echo "ERRO: Nao foi possivel ler Encryption__MasterKey."
        exit 1
    fi
    if ! prompt_input "  Jwt__Key (32+ caracteres)                : " jwt_key true; then
        echo "ERRO: Nao foi possivel ler Jwt__Key."
        exit 1
    fi
    if ! prompt_input "  DOCKER_AGENT_KEY (32+ caracteres)        : " agent_key true; then
        echo "ERRO: Nao foi possivel ler DOCKER_AGENT_KEY."
        exit 1
    fi

    echo ""
    echo "Aplicando valores no .env..."

    if [ -n "$db_conn" ]; then
        sed -i "s|^ConnectionStrings__DefaultConnection=.*|ConnectionStrings__DefaultConnection=${db_conn}|" .env
    fi
    if [ -n "$enc_key" ]; then
        sed -i "s|^Encryption__MasterKey=.*|Encryption__MasterKey=${enc_key}|" .env
    fi
    if [ -n "$jwt_key" ]; then
        sed -i "s|^Jwt__Key=.*|Jwt__Key=${jwt_key}|" .env
    fi
    if [ -n "$agent_key" ]; then
        sed -i "s|^DOCKER_AGENT_KEY=.*|DOCKER_AGENT_KEY=${agent_key}|" .env
    fi

    echo "" >> .env
    echo "DUNCKOPS_LICENSE_KEY=${DUNCKOPS_LICENSE_KEY}" >> .env

    echo ""
    echo ".env configurado. Verifique o arquivo antes de continuar."
else
    echo "Arquivo .env ja existe, mantendo configuracao atual."
fi

echo ""
echo "[4/6] Baixando imagens Docker..."

COMPOSE_ARGS="-f $COMPOSE_FILE"

if [ -f "$DOCKER_OPS_FILE" ]; then
    docker compose $COMPOSE_ARGS -f "$DOCKER_OPS_FILE" pull
else
    docker compose $COMPOSE_ARGS pull
fi

echo ""
echo "[5/6] Iniciando servicos..."

if [ -f "$DOCKER_OPS_FILE" ]; then
    docker compose $COMPOSE_ARGS -f "$DOCKER_OPS_FILE" up -d
else
    docker compose $COMPOSE_ARGS up -d
fi

echo ""
echo "[6/6] Verificando status..."

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
