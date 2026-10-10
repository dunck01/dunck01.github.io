#!/usr/bin/env bash
# Public operator settings only. Never source .env or read certificate/private-key files.
configure_sqlserver_profile() {
    local persist="${1:-false}" key value enabled resolved
    local supplied=()
    local keys=(MULTI_ENGINE_OPERATIONS_ENABLED SQLSERVER_PROVISIONING_ENCRYPT SQLSERVER_PROVISIONING_TRUST_SERVER_CERTIFICATE
        SQLSERVER_PROVISIONING_TLS_PROFILE_ENABLED SQLSERVER_PROVISIONING_COMPANY_ID
        SQLSERVER_PROVISIONING_TLS_VOLUME SQLSERVER_PROVISIONING_TRUST_VOLUME SQLSERVER_PROVISIONING_TLS_HOSTNAME
        SQLSERVER_PROVISIONING_CA_SHA256 SQLSERVER_OPERATIONS_RUNTIME_IMAGE SQLSERVER_OPERATIONS_BACKUP_VOLUME
        SQLSERVER_OPERATIONS_SIGNING_VOLUME SQLSERVER_OPERATIONS_SIGNING_PUBLIC_KEY_SHA256
        SQLSERVER_OPERATIONS_UNVERIFIED_OPT_IN SQLSERVER_OPERATIONS_TIMEOUT_SECONDS SQLSERVER_MANAGED_SETUP_ENABLED
        SQLSERVER_RUNTIME_APPROVAL_PAYLOAD SQLSERVER_RUNTIME_APPROVAL_SIGNATURE SQLSERVER_RUNTIME_APPROVAL_PUBLIC_KEY
        SQLSERVER_RUNTIME_APPROVAL_PUBLIC_KEY_SHA256)
    resolved="$(docker compose $COMPOSE_ARGS config --environment)" || return 1
    enabled="$(printf '%s\n' "$resolved" | sed -n 's/^SQLSERVER_PROVISIONING_TLS_PROFILE_ENABLED=//p')"
    case "$enabled" in ""|true|false) ;; *) echo "ERRO: SQLSERVER_PROVISIONING_TLS_PROFILE_ENABLED deve ser true ou false."; return 1 ;; esac
    for key in "${keys[@]}"; do
        if [[ -v "$key" ]]; then supplied+=("$key"); fi
        value="$(printf '%s\n' "$resolved" | sed -n "s/^${key}=//p")"
        if [[ "$key" == SQLSERVER_MANAGED_SETUP_ENABLED && -n "$value" && "$value" != true && "$value" != false ]]; then return 1; fi
        if [[ "$key" == SQLSERVER_RUNTIME_APPROVAL_PUBLIC_KEY_SHA256 && -n "$value" && ! "$value" =~ ^[a-f0-9]{64}$ ]]; then return 1; fi
        if [[ "$key" == SQLSERVER_RUNTIME_APPROVAL_PAYLOAD || "$key" == SQLSERVER_RUNTIME_APPROVAL_SIGNATURE ]]; then
            [[ -z "$value" || "$value" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
        fi
        if [[ "$enabled" == true ]]; then
            case "$key" in
                *_ENABLED|*_OPT_IN|*_ENCRYPT|*_CERTIFICATE) [[ -z "$value" || "$value" == true || "$value" == false ]] || return 1 ;;
                *_COMPANY_ID) [[ -z "$value" || "$value" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || return 1 ;;
                *_VOLUME) [[ -z "$value" || "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{1,254}$ ]] || return 1 ;;
                *_SHA256) [[ -z "$value" || "$value" =~ ^[a-f0-9]{64}$ ]] || return 1 ;;
                *_IMAGE) [[ -z "$value" || "$value" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1 ;;
                *_HOSTNAME) [[ -z "$value" || "$value" =~ ^[a-z0-9][a-z0-9.-]{0,251}[a-z0-9]$ ]] || return 1 ;;
                *_SECONDS) [[ -z "$value" || ( "$value" =~ ^[0-9]{2,4}$ && "$value" -ge 60 && "$value" -le 7200 ) ]] || return 1 ;;
            esac
        fi
        export "$key=$value"
    done
    if [[ "$enabled" == true ]]; then
        for key in SQLSERVER_PROVISIONING_COMPANY_ID SQLSERVER_PROVISIONING_TLS_VOLUME SQLSERVER_PROVISIONING_TRUST_VOLUME \
            SQLSERVER_PROVISIONING_TLS_HOSTNAME SQLSERVER_PROVISIONING_CA_SHA256 SQLSERVER_OPERATIONS_RUNTIME_IMAGE \
            SQLSERVER_OPERATIONS_BACKUP_VOLUME SQLSERVER_OPERATIONS_SIGNING_VOLUME SQLSERVER_OPERATIONS_SIGNING_PUBLIC_KEY_SHA256; do
            if [[ -z "${!key}" ]]; then echo "ERRO: perfil SQL requer $key."; return 1; fi
        done
        if [[ "$SQLSERVER_OPERATIONS_UNVERIFIED_OPT_IN" != true || "$MULTI_ENGINE_OPERATIONS_ENABLED" != true
            || "${SQLSERVER_PROVISIONING_ENCRYPT:-true}" != true || "${SQLSERVER_PROVISIONING_TRUST_SERVER_CERTIFICATE:-false}" != false
            || ! -f docker-compose.sqlserver-tls.yml ]]; then
            echo "ERRO: perfil SQL requer ambos opt-ins, TLS verificado e overlay instalado."; return 1
        fi
        COMPOSE_ARGS="$COMPOSE_ARGS -f docker-compose.sqlserver-tls.yml"
    fi
    if [[ "$persist" == true ]]; then
        for key in "${supplied[@]}"; do set_env_value "$key" "${!key}"; done
    fi
}
