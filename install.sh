#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

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
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

set_env_value() {
    local key="$1"
    local value="$2"

    if [[ "$key" == INSTALLATION_FINGERPRINT || "$key" == DUNCKOPS_SETUP_TOKEN ]]; then
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"
        value="${value//\$/\$\$}"
        value="\"$value\""
    fi
    if grep -q "^${key}=" .env; then
        sed -i "/^${key}=/d" .env
        printf '%s=%s\n' "$key" "$value" >> .env
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}

# Read only data, never source an operator-provided .env as shell code.
read_env_value() {
    local value
    value="$(sed -n "s/^${1}=//p" .env | tail -n 1)"
    value="${value%$'\r'}"
    if [[ "$value" == \'*\' ]]; then
        value="${value:1:${#value}-2}"
        value="${value//\\\'/\'}"
    elif [[ "$value" == \"*\" ]]; then
        value="${value:1:${#value}-2}"
        value="${value//\$\$/\$}"
        value="${value//\\\"/\"}"
        value="${value//\\\\/\\}"
    fi
    printf '%s' "$value"
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

resolve_latest_release_version() {
    local metadata version
    if command -v curl >/dev/null 2>&1; then
        metadata="$(curl -fsSL --max-time 20 "${BASE_URL}/version.json")" || return 1
    elif command -v wget >/dev/null 2>&1; then
        metadata="$(wget -q -T 20 -O - "${BASE_URL}/version.json")" || return 1
    else
        return 1
    fi
    version="$(printf '%s\n' "$metadata" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p')"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s' "$version"
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

    download_file "scripts/backup-before-update.sh" "scripts/backup-before-update.sh"
    chmod +x "scripts/backup-before-update.sh"
    echo "  scripts/backup-before-update.sh (atualizado)"
}

build_postgres_images() {
    local dockerfile="infra/docker/postgres/Dockerfile"
    local context="infra/docker/postgres"
    local majors="${POSTGRES_IMAGE_MAJORS:-15 16 17 18}"

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
    local config timeout runtime_overrides snapshot_overrides engine image key value multi sql restore_pull service override_key
    config="$(docker compose $COMPOSE_ARGS config --format json)"
    local release_version
    release_version="$(docker compose $COMPOSE_ARGS config --environment | sed -n 's/^DUNCKOPS_VERSION=//p')"
    if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ERRO: DUNCKOPS_VERSION exige release X.Y.Z publicada; nunca latest. Nenhum pull ou startup executado."
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
            echo "ERRO: runtimes experimentais indisponiveis. Verifique REGISTRY_OWNER/DUNCKOPS_VERSION e a publicacao de ambas as imagens; ou desative PHYSICAL_SNAPSHOTS_ENABLED. Nenhum servico foi iniciado."
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
                echo "ERRO: ${engine}-snapshot-runtime indisponivel. Verifique REGISTRY_OWNER/DUNCKOPS_VERSION e a publicacao da imagem; ou configure o override com uma imagem instalada localmente; ou desative PHYSICAL_SNAPSHOTS_ENABLED. Nenhum servico foi iniciado."
                return 1
            fi
        done
    fi
    if [ "$multi" = true ]; then
        if [ ! -f "$DOCKER_OPS_FILE" ]; then
            echo "ERRO: Compose de ferramentas ausente; nenhum servico foi iniciado."
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

package_manager_is_busy() {
    local lock_file
    local lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/cache/apt/archives/lock
    )

    for lock_file in "${lock_files[@]}"; do
        if [ -e "$lock_file" ] && fuser "$lock_file" >/dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}

if ! command -v docker &> /dev/null; then
    echo "Docker nao encontrado. Instalando..."
    echo ""

    if command -v fuser &> /dev/null; then
        while package_manager_is_busy; do
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

if [ -z "${DUNCKOPS_VERSION:-}" ]; then
    DUNCKOPS_VERSION="$(read_env_value DUNCKOPS_VERSION)"
fi
if [ -z "${DUNCKOPS_VERSION:-}" ]; then
    DUNCKOPS_VERSION="$(resolve_latest_release_version || true)"
    if [ -z "$DUNCKOPS_VERSION" ]; then
        echo "ERRO: nao foi possivel detectar release publicada. Defina DUNCKOPS_VERSION=X.Y.Z e tente novamente."
        exit 1
    fi
    echo "Release publicada detectada: $DUNCKOPS_VERSION"
fi
if [[ ! "$DUNCKOPS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERRO: DUNCKOPS_VERSION exige release X.Y.Z publicada, nunca latest."
    exit 1
fi
set_env_value "DUNCKOPS_VERSION" "$DUNCKOPS_VERSION"
export DUNCKOPS_VERSION

chmod 600 .env

# Persisted identity wins over process environment on reinstall.
fingerprint="$(read_env_value Installation__Fingerprint)"
fingerprint="${fingerprint:-$(read_env_value INSTALLATION_FINGERPRINT)}"
fingerprint="${fingerprint:-${Installation__Fingerprint:-${INSTALLATION_FINGERPRINT:-}}}"
fingerprint="${fingerprint:-$(random_secret)}"
setup_token="$(read_env_value Setup__Token)"
setup_token="${setup_token:-$(read_env_value DUNCKOPS_SETUP_TOKEN)}"
setup_token="${setup_token:-${Setup__Token:-${DUNCKOPS_SETUP_TOKEN:-}}}"
if [[ ${#fingerprint} -gt 200 || -z "${fingerprint//[[:space:]]/}" || "$fingerprint" == *[$'\r\n']* ]]; then
    echo "ERRO: fingerprint deve ter 1-200 caracteres, sem quebras de linha."
    exit 1
fi
if [[ -n "$setup_token" && ( ${#setup_token} -lt 32 || -z "${setup_token//[[:space:]]/}" || "$setup_token" == "$fingerprint" || "$setup_token" == *[$'\r\n']* ) ]]; then
    echo "ERRO: token de setup deve ter pelo menos 32 caracteres, ser distinto do fingerprint e seguro para .env."
    exit 1
fi
set_env_value "INSTALLATION_FINGERPRINT" "$fingerprint"
if [ -n "$setup_token" ]; then
    set_env_value "DUNCKOPS_SETUP_TOKEN" "$setup_token"
fi
export INSTALLATION_FINGERPRINT="$fingerprint" Installation__Fingerprint="$fingerprint"
export DUNCKOPS_SETUP_TOKEN="$setup_token" Setup__Token="$setup_token"

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
echo "[5/5] Iniciando servicos..."

COMPOSE_PROFILES= docker compose $COMPOSE_ARGS up -d

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
echo "  2. Primeiro acesso: entre com Owner da empresa na conta DunckOps comercial"
echo "     Informe sua chave de licenca, se tiver uma; sem chave, o fluxo comercial configura licenca gratuita"
echo "  3. Depois use http://IP_DA_VPS:${WEB_PORT:-9000}/dashboard"
echo ""
