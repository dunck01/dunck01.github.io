#!/usr/bin/env bash
# Compose remains the authority for dotenv syntax and project-name precedence.
install_compose() {
    docker compose -f docker-compose.prod.yml -f docker-compose.docker-ops.prod.yml "$@"
}

parse_install_binding() {
    local value="$1"
    BIND_HOST=0.0.0.0
    BIND_PORT="$value"
    if [[ "$value" =~ ^\[([0-9a-fA-F:.]+)\]:([0-9]+)$ ]]; then
        BIND_HOST="${BASH_REMATCH[1]}"; BIND_PORT="${BASH_REMATCH[2]}"
    elif [[ "$value" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
        BIND_HOST="${BASH_REMATCH[1]}"; BIND_PORT="${BASH_REMATCH[2]}"
    fi
    [[ "$BIND_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$BIND_PORT <= 65535 )) || {
        echo "ERRO: binding invalido: $value. Use PORTA, IPv4:PORTA ou [IPv6]:PORTA; sem intervalos." >&2
        return 1
    }
}

bindings_collide() {
    [ "$2" = "$4" ] || return 1
    # IPv6 wildcard may also reserve IPv4 (dual stack); fail conservatively.
    [[ "$1" = '*' || "$3" = '*' || "$1" = :: || "$3" = :: || "$1" = *:*[fF][fF][fF][fF]:* || "$3" = *:*[fF][fF][fF][fF]:* ]] && return 0
    if [[ "$1" = *:* || "$3" = *:* ]]; then
        [[ "$1" = *:* && "$3" = *:* ]] || return 1
        # Different textual IPv6 forms may denote the same address.
        return 0
    fi
    [[ "$1" = 0.0.0.0 || "$3" = 0.0.0.0 || "$1" = "$3" ]]
}

detect_install_access_host() {
    local octet
    local -a octets
    INSTALL_ACCESS_HOST=""
    INSTALL_ACCESS_LABEL="endereco local de rota/interface"
    if [ "${1:-offline}" = online ] && command -v curl >/dev/null 2>&1; then
        INSTALL_ACCESS_HOST="$(curl -q -4 -fsS --connect-timeout 2 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
        [[ "$INSTALL_ACCESS_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || INSTALL_ACCESS_HOST=""
        if [ -n "$INSTALL_ACCESS_HOST" ]; then
            IFS=. read -r -a octets <<< "$INSTALL_ACCESS_HOST"
            for octet in "${octets[@]}"; do
                if (( 10#$octet > 255 )) || [[ "$octet" != 0 && "$octet" = 0* ]]; then INSTALL_ACCESS_HOST=""; fi
            done
        fi
        [ -z "$INSTALL_ACCESS_HOST" ] || INSTALL_ACCESS_LABEL="IPv4 publico de saida (pode ser NAT)"
    fi
    if [ -z "$INSTALL_ACCESS_HOST" ] && command -v ip >/dev/null 2>&1; then
        # Route lookup is local only; never transmit packets in offline mode.
        INSTALL_ACCESS_HOST="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev" && $(i+1) ~ /^(docker|br-|veth|lo)/) next; for(i=1;i<NF;i++) if($i=="src") print $(i+1)}' || true)"
        if [ -z "$INSTALL_ACCESS_HOST" ]; then
            INSTALL_ACCESS_HOST="$(ip -o -4 addr show scope global 2>/dev/null | awk '$2 !~ /^(docker|br-|veth|lo)/ {split($4,a,"/"); print a[1]; exit}' || true)"
        fi
    fi
}

configure_install_ports() {
    command -v curl >/dev/null 2>&1 || { echo "ERRO: instale curl para validar prontidao HTTP local antes de iniciar servicos."; return 1; }
    local keys=(WEB_PORT API_PORT LOCAL_MINIO_API_PORT LOCAL_MINIO_CONSOLE_PORT)
    local defaults=(9000 9100 9002 9001) services=(web api minio minio) targets=(80 8080 9000 9001)
    local -a values hosts ports explicit order
    local environment project sockets sockets_v6 rows="" id key value i j candidate busy host port target service directory owner socket endpoint own hint
    environment="$(install_compose config --environment)" || return 1
    project="$(install_compose config --format json | sed -n 's/^  "name": "\([^"]*\)".*/\1/p')"
    [ -n "$project" ] || { echo "ERRO: nome efetivo Compose nao resolvido."; return 1; }
    if command -v ss >/dev/null 2>&1; then
        sockets="$(ss -4 -H -ltnp)" || return 1
        sockets_v6="$(ss -6 -H -ltnp)" || return 1
        # ss may render both wildcard families as '*'; retain family before matching Docker.
        sockets="$(printf '%s\n' "$sockets" | awk '{sub(/^\*:/,"0.0.0.0:",$4); print}')"$'\n'"$(printf '%s\n' "$sockets_v6" | awk '{sub(/^\*:/,"[::]:",$4); print}')"
    elif command -v netstat >/dev/null 2>&1; then
        sockets="$(netstat -lntp)" || return 1
    else
        echo "ERRO: instale iproute2 (ss) ou net-tools (netstat)."; return 1
    fi
    local ids
    ids="$(docker ps -q)" || return 1
    for id in $ids; do
        rows+="$(docker inspect --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{.HostIp}}|{{.HostPort}}|{{$port}}|{{index $.Config.Labels "com.docker.compose.service"}}|{{index $.Config.Labels "com.docker.compose.project.working_dir"}}|{{index $.Config.Labels "com.docker.compose.project"}}{{println}}{{end}}{{end}}' "$id")"$'\n' || return 1
    done
    for i in "${!keys[@]}"; do
        key="${keys[i]}"
        value="$(printf '%s\n' "$environment" | sed -n "s/^${key}=//p")"
        explicit[i]=false
        [ -z "$value" ] || explicit[i]=true
        value="${value:-${defaults[i]}}"
        parse_install_binding "$value" || return 1
        values[i]="$value"; hosts[i]="$BIND_HOST"; ports[i]="$BIND_PORT"
    done
    for i in "${!keys[@]}"; do [ "${explicit[i]}" = true ] || order+=("$i"); done
    for i in "${!keys[@]}"; do [ "${explicit[i]}" = false ] || order+=("$i"); done
    for i in "${order[@]}"; do
        candidate=9003
        while :; do
            busy=false
            while IFS='|' read -r host port target service directory owner; do
                [[ "$target" = */tcp ]] || continue
                bindings_collide "${hosts[i]}" "${ports[i]}" "$host" "$port" || continue
                if [[ "$directory" != "$(pwd -P)" || "$owner" != "$project" || "$service" != "${services[i]}" || "$target" != "${targets[i]}/tcp" ]]; then
                    busy=true
                elif [[ "$host" != "${hosts[i]}" ]] && ! { [ "${hosts[i]}" = 0.0.0.0 ] && [ "$host" = :: ]; }; then
                    busy=true
                fi
            done <<< "$rows"
            while IFS= read -r socket; do
                endpoint="$(awk '{print $4}' <<< "$socket")"
                port="${endpoint##*:}"; host="${endpoint%:*}"; host="${host#[}"; host="${host%]}"
                bindings_collide "${hosts[i]}" "${ports[i]}" "$host" "$port" || continue
                own=false
                # Exempt only exact Docker proxy sockets, never all sockets on an owned port.
                if [[ "$socket" = *docker-proxy* ]]; then
                    while IFS='|' read -r owner target service directory key value; do
                        if [[ "$owner" = "$host" && "$target" = "$port" && "$service" = "${targets[i]}/tcp" && "$directory" = "${services[i]}" && "$key" = "$(pwd -P)" && "$value" = "$project" ]]; then own=true; fi
                    done <<< "$rows"
                fi
                [ "$own" = true ] || busy=true
            done <<< "$sockets"
            for j in "${!keys[@]}"; do
                [ "$i" = "$j" ] || ! bindings_collide "${hosts[i]}" "${ports[i]}" "${hosts[j]}" "${ports[j]}" || busy=true
            done
            [ "$busy" = true ] || break
            if [ "${explicit[i]}" = true ]; then
                echo "ERRO: ${keys[i]}=${values[i]} conflita; nenhum servico sera interrompido."
                echo "Edite somente esse binding em $INSTALL_DIR/.env ou execute (troque 9200 por porta livre):"
                hint=9200
                if [[ "${values[i]}" = *:* ]]; then
                    hint="${hosts[i]}:9200"
                    [[ "${hosts[i]}" != *:* ]] || hint="[${hosts[i]}]:9200"
                fi
                if [ -n "${BUNDLE_DIR:-}" ]; then
                    printf 'sudo env DUNCKOPS_INSTALL_DIR=%q %s=%q bash %q\n' "$INSTALL_DIR" "${keys[i]}" "$hint" "$BUNDLE_DIR/install-offline.sh"
                else
                    printf 'curl -fsSL %q | sudo env DUNCKOPS_INSTALL_DIR=%q %s=%q bash\n' "${BASE_URL}/install.sh" "$INSTALL_DIR" "${keys[i]}" "$hint"
                fi
                return 1
            fi
            (( candidate <= 65535 )) || return 1
            values[i]="$candidate"; ports[i]="$candidate"; candidate=$((candidate+1))
        done
    done
    # Validate addresses with Compose before persisting anything.
    for i in "${!keys[@]}"; do export "${keys[i]}=${values[i]}"; done
    install_compose config --quiet || return 1
    for i in "${!keys[@]}"; do
        set_env_value "${keys[i]}" "${values[i]}"
        echo "Binding confirmado: ${keys[i]}=${values[i]}"
    done
    local cors
    cors="$(printf '%s\n' "$environment" | sed -n 's/^CORS_ORIGINS=//p')"
    if [ -z "$cors" ] || { [ "$(read_env_value DUNCKOPS_INSTALL_PORTS_PENDING)" = true ] && [ ! "${CORS_ORIGINS+x}" ] && [ "$cors" = http://localhost:9000 ]; }; then
        cors="http://localhost:${ports[0]}"
    fi
    set_env_value CORS_ORIGINS "$cors"; export CORS_ORIGINS="$cors"
    configure_install_minio_endpoint "$environment"
    set_env_value DUNCKOPS_INSTALL_PORTS_PENDING false
}

configure_install_minio_endpoint() {
    local endpoint generated
    endpoint="$(printf '%s\n' "$1" | sed -n 's/^LOCAL_MINIO_EXTERNAL_ENDPOINT=//p')"
    generated="$(printf '%s\n' "$1" | sed -n 's/^DUNCKOPS_INSTALL_MINIO_ENDPOINT=//p')"
    if [ -z "$endpoint" ] || { [ -n "$generated" ] && [ "$endpoint" = "$generated" ]; }; then
        install_local_endpoint "$LOCAL_MINIO_API_PORT" || return 1
        endpoint="$LOCAL_ENDPOINT"
        [[ "$LOCAL_MINIO_API_PORT" = *:* ]] || endpoint="http://localhost:$BIND_PORT"
        # Persist for future direct Compose invocations, not only this process.
        sed -i '/^LOCAL_MINIO_EXTERNAL_ENDPOINT=/d; /^DUNCKOPS_INSTALL_MINIO_ENDPOINT=/d' .env
        printf 'LOCAL_MINIO_EXTERNAL_ENDPOINT=%s\n' "$endpoint" >> .env
        printf 'DUNCKOPS_INSTALL_MINIO_ENDPOINT=%s\n' "$endpoint" >> .env
    fi
    export LOCAL_MINIO_EXTERNAL_ENDPOINT="$endpoint"
}

install_local_endpoint() {
    parse_install_binding "$1" || return 1
    case "$BIND_HOST" in 0.0.0.0) BIND_HOST=127.0.0.1 ;; ::) BIND_HOST=::1 ;; esac
    [[ "$BIND_HOST" != *:* ]] || BIND_HOST="[$BIND_HOST]"
    LOCAL_ENDPOINT="http://$BIND_HOST:$BIND_PORT"
}

wait_install_ready() {
    local value path attempt ready endpoint status
    command -v curl >/dev/null 2>&1 || { echo "ERRO: curl necessario para validar prontidao local."; return 1; }
    for value in "$WEB_PORT" "$API_PORT"; do
        path=/; [ "$value" != "$API_PORT" ] || path=/health
        install_local_endpoint "$value" || return 1
        endpoint="$LOCAL_ENDPOINT"
        ready=false
        for ((attempt=0; attempt<30; attempt++)); do
            if status="$(curl -q --noproxy '*' -fsS --connect-timeout 2 --max-time 3 "$endpoint$path" -o /dev/null -w '%{http_code}')" && [[ "$status" = 2[0-9][0-9] ]]; then
                ready=true
                break
            fi
            sleep 2
        done
        if [ "$ready" = false ]; then
            echo "ERRO: prontidao local falhou em $endpoint$path; instalacao NAO concluida."
            install_compose ps
            echo "Diagnostico privado: docker compose -f docker-compose.prod.yml -f docker-compose.docker-ops.prod.yml logs --tail 100 web api"
            return 1
        fi
    done
}

report_install_access() {
    local path="${1:-login}" web_port
    install_local_endpoint "$API_PORT" || return 1
    echo "API verificada nesta VPS: $LOCAL_ENDPOINT/health (diagnostico local)."
    install_local_endpoint "$WEB_PORT" || return 1
    web_port="$BIND_PORT"
    echo "Web verificada nesta VPS: $LOCAL_ENDPOINT (diagnostico local, nao login remoto)."
    echo "Bindings: Web=$WEB_PORT API=$API_PORT MinIO=$LOCAL_MINIO_API_PORT console=$LOCAL_MINIO_CONSOLE_PORT"
    echo "Acesso com credenciais: use dominio HTTPS no proxy existente do Coolify, apontando para binding Web alcancavel pelo proxy."
    echo "Alternativa: na SUA maquina, edite usuario, host e porta SSH conforme acesso administrativo real:"
    echo "  SSH_USER='usuario'; SSH_HOST='host-ou-dns-da-vps'; SSH_PORT='22'"
    printf '  ssh -N -o ExitOnForwardFailure=yes -L %q -p "$SSH_PORT" "$SSH_USER@$SSH_HOST"\n' "127.0.0.1:$web_port:$BIND_HOST:$web_port"
    echo "Com tunel ativo, abra http://localhost:$web_port/$path; porta local deve estar livre."
    echo "Nunca envie senha, chave de licenca ou token de setup por HTTP publico."
    if [ -n "${INSTALL_ACCESS_HOST:-}" ]; then
        echo "Diagnostico remoto: $INSTALL_ACCESS_LABEL = $INSTALL_ACCESS_HOST; Web publicada em $WEB_PORT."
        echo "Nao garante alcance externo, NAT/firewall ou compatibilidade com binding restrito; nao use para credenciais."
    else
        echo "Endereco remoto nao detectado; use host/DNS administrativo conhecido."
    fi
}
