#!/usr/bin/env bash
set -euo pipefail

echo "=============================================="
echo "  DunckOps Platform - Instalador de Producao"
echo "=============================================="
echo ""

REGISTRY_OWNER="${REGISTRY_OWNER:-dunck01}"
BASE_URL="${DUNCKOPS_BASE_URL:-https://get.dunckops.com}"
COMMERCIAL_PUBLIC_KEY_URL="${DUNCKOPS_COMMERCIAL_PUBLIC_KEY_URL:-https://api.dunckops.com/license-public.pem}"
DEFAULT_DB_PASSWORD="${DUNCKOPS_DEFAULT_DB_PASSWORD:-pitr-local}"
INSTALL_DIR="${DUNCKOPS_INSTALL_DIR:-/opt/dunckops}"
DEFAULT_INSTALLATION_NAME="${DUNCKOPS_INSTALLATION_NAME:-$(hostname 2> /dev/null || echo dunckops-vps)}"
DEFAULT_LICENSE_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzgcIq8VPzkF8RSN2S4Lt\nFT+SKD10mKci8TrBOLx36LAx3kW+afo+rZKZMEoUDyFnMI9qZwmLXDuDFvvmcSq6\nv7wg7UgoB638FxMc9ByncnZP6I7JbjzwLDP04xFCgKlVbYfvDhUQQLhCfewGB1Ua\nYOslsF5BnPoFk0lK+MtONbflwDrsyY7re3chTPyIgHOtDicDFuroySON1seuMx8c\nuTAUOIreQRuBnUT4jck8fdZ45AsfB7u4cW5rU94jEAB/MEz2rXV6McSlBCt3ZgaO\nmLnmqGuPoTPUcT8BytEi6I1YrBccj9Gyu3xNRfJPjWM2STI/TW4qXGDaH402daNN\nEQIDAQAB\n-----END PUBLIC KEY-----'

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
        sed -i "/^${key}=/d" .env
        printf '%s=%s\n' "$key" "$value" >> .env
    else
        printf '%s=%s\n' "$key" "$value" >> .env
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

try_download_license_public_key() {
    local public_key=""

    if command -v curl &> /dev/null; then
        public_key="$(curl -fsSL "$COMMERCIAL_PUBLIC_KEY_URL" 2> /dev/null || true)"
        if [ -z "$public_key" ]; then
            public_key="$(curl -fsSL "${BASE_URL}/license-public.pem" 2> /dev/null || true)"
        fi
    elif command -v wget &> /dev/null; then
        public_key="$(wget -q "$COMMERCIAL_PUBLIC_KEY_URL" -O - 2> /dev/null || true)"
        if [ -z "$public_key" ]; then
            public_key="$(wget -q "${BASE_URL}/license-public.pem" -O - 2> /dev/null || true)"
        fi
    fi

    if printf '%s' "$public_key" | grep -q "BEGIN PUBLIC KEY"; then
        printf '%s' "$public_key" | sed ':a;N;$!ba;s/\n/\\n/g'
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

prepare_install_dir() {
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
}

pull_managed_images() {
    docker compose $COMPOSE_ARGS pull

    if [ -f "$DOCKER_OPS_FILE" ]; then
        docker compose $COMPOSE_ARGS --profile tools pull backup-runtime
    fi
}

if ! command -v docker &> /dev/null; then
    echo "Docker nao encontrado. Instalando..."
    echo ""
    
    if command -v pgrep &> /dev/null; then
        while pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null || pgrep -f unattended-upgrades >/dev/null || pgrep -f unattended-upgr >/dev/null; do
            echo "Aguardando o sistema liberar o gerenciador de pacotes... (isso pode levar alguns minutos em uma VPS nova)"
            sleep 10
        done
    fi

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

prepare_install_dir

if [ -z "${DUNCKOPS_LICENSE_KEY:-}" ] && [ -f .env ]; then
    existing_key="$(grep '^DUNCKOPS_LICENSE_KEY=' .env | cut -d'=' -f2- || true)"
    if [ -n "$existing_key" ]; then
        DUNCKOPS_LICENSE_KEY="$existing_key"
        echo "License key encontrada no .env existente."
    fi
fi

if [ -n "${DUNCKOPS_LICENSE_KEY:-}" ]; then
    export DUNCKOPS_LICENSE_KEY
fi

if [ -z "${LICENSE_PUBLIC_KEY:-}" ] && [ -f .env ]; then
    existing_public_key="$(grep '^LICENSE_PUBLIC_KEY=' .env | cut -d'=' -f2- || true)"
    if [ -n "$existing_public_key" ]; then
        LICENSE_PUBLIC_KEY="$existing_public_key"
        echo "License public key encontrada no .env existente."
    fi
fi

if [ -n "${LICENSE_PUBLIC_KEY:-}" ]; then
    export LICENSE_PUBLIC_KEY
fi

if [ -z "${INSTALLATION_NAME:-}" ] && [ -f .env ]; then
    existing_installation_name="$(grep '^INSTALLATION_NAME=' .env | cut -d'=' -f2- || true)"
    if [ -n "$existing_installation_name" ]; then
        INSTALLATION_NAME="$existing_installation_name"
    fi
fi

INSTALLATION_NAME="${INSTALLATION_NAME:-$DEFAULT_INSTALLATION_NAME}"
export INSTALLATION_NAME

if [ -z "${LICENSE_PUBLIC_KEY:-}" ]; then
    downloaded_public_key="$(try_download_license_public_key)"
    if [ -n "$downloaded_public_key" ]; then
        LICENSE_PUBLIC_KEY="$downloaded_public_key"
        export LICENSE_PUBLIC_KEY
        echo "License public key baixada automaticamente."
    elif [ -n "$DEFAULT_LICENSE_PUBLIC_KEY" ]; then
        LICENSE_PUBLIC_KEY="$DEFAULT_LICENSE_PUBLIC_KEY"
        export LICENSE_PUBLIC_KEY
        echo "License public key padrao aplicada pelo instalador."
    fi
fi

echo ""
echo "[1/5] Preparando instalacao..."
echo "Usando imagens publicas em ghcr.io/${REGISTRY_OWNER}."
echo "Diretorio de instalacao: $INSTALL_DIR"

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

    minio_access_key="dunckops$(random_secret | cut -c 1-16)"
    minio_secret_key="$(random_secret)"
    enc_key="$(random_secret)"
    jwt_key="$(random_secret)"
    agent_key="$(random_secret)"

    echo ""
    echo "Aplicando valores no .env..."

    set_env_value "DUNCKOPS_DB_PASSWORD" "$DEFAULT_DB_PASSWORD"
    set_env_value "LOCAL_MINIO_ACCESS_KEY" "$minio_access_key"
    set_env_value "LOCAL_MINIO_SECRET_KEY" "$minio_secret_key"
    set_env_value "Encryption__MasterKey" "$enc_key"
    set_env_value "Jwt__Key" "$jwt_key"
    set_env_value "DOCKER_AGENT_KEY" "$agent_key"
    if [ -n "${DUNCKOPS_LICENSE_KEY:-}" ]; then
        set_env_value "DUNCKOPS_LICENSE_KEY" "$DUNCKOPS_LICENSE_KEY"
    fi
    if [ -n "${LICENSE_PUBLIC_KEY:-}" ]; then
        set_env_value "LICENSE_PUBLIC_KEY" "$LICENSE_PUBLIC_KEY"
    fi
    set_env_value "CommercialAuth__PublicKeyUrl" "$COMMERCIAL_PUBLIC_KEY_URL"
    set_env_value "INSTALLATION_NAME" "$INSTALLATION_NAME"

    echo ""
    echo ".env configurado. Verifique o arquivo antes de continuar."
else
    echo "Arquivo .env ja existe, mantendo configuracao atual."
fi

if ! grep -q "^DUNCKOPS_DB_PASSWORD=" .env; then
    set_env_value "DUNCKOPS_DB_PASSWORD" "$DEFAULT_DB_PASSWORD"
fi

if ! grep -q "^LICENSE_PUBLIC_KEY=." .env; then
    set_env_value "LICENSE_PUBLIC_KEY" "$LICENSE_PUBLIC_KEY"
fi

if ! grep -q "^CommercialAuth__PublicKeyUrl=" .env; then
    set_env_value "CommercialAuth__PublicKeyUrl" "$COMMERCIAL_PUBLIC_KEY_URL"
fi

if ! grep -q "^INSTALLATION_NAME=" .env; then
    set_env_value "INSTALLATION_NAME" "$INSTALLATION_NAME"
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
    COMPOSE_ARGS="$COMPOSE_ARGS -f $DOCKER_OPS_FILE"
fi

pull_managed_images

echo ""
echo "Construindo imagens customizadas do PostgreSQL..."
build_postgres_images

echo ""
echo "[5/5] Iniciando servicos..."

docker compose $COMPOSE_ARGS up -d

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
echo "  Atualizar: cd $INSTALL_DIR && ./scripts/update.sh"
echo "  Rollback : cd $INSTALL_DIR && ./scripts/rollback.sh <versao>"
echo ""
echo "Proximos passos:"
echo "  1. Acesse http://IP_DA_VPS:${WEB_PORT:-9000}/login"
echo "  2. Entre com sua conta DunckOps e informe sua chave de licenca, se tiver uma"
echo "     Sem chave, uma licenca gratuita sera configurada automaticamente"
echo "  3. Depois use http://IP_DA_VPS:${WEB_PORT:-9000}/dashboard"
echo ""
