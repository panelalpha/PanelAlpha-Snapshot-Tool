# ======================
# DATABASE HELPERS
# ======================

# Read a variable from an env file; strips surrounding quotes.
get_env_var() {
    local key="$1"
    local file="$2"
    local value

    value=$(grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d'=' -f2- || true)
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    echo "$value"
}

get_container_mariadb_password() {
    local container="$1"
    local password=""

    password=$(docker exec "$container" printenv MYSQL_PASSWORD 2>/dev/null || true)
    [[ -z "$password" ]] && password=$(docker exec "$container" printenv MARIADB_PASSWORD 2>/dev/null || true)
    echo "$password"
}

test_mariadb_connection() {
    local container="$1"
    local username="$2"
    local password="$3"

    [[ -n "$container" && -n "$username" && -n "$password" ]] || return 1
    timeout "$MARIADB_TIMEOUT" docker exec -e MYSQL_PWD="$password" "$container" \
        mariadb -u "$username" -e "SELECT 1;" >/dev/null 2>&1
}

mariadb_exec() {
    local container="$1"
    local username="$2"
    local password="$3"
    shift 3
    docker exec -e MYSQL_PWD="$password" "$container" mariadb -u "$username" "$@"
}

mariadb_exec_stdin() {
    local container="$1"
    local username="$2"
    local password="$3"
    local database="${4:-}"

    if [[ -n "$database" ]]; then
        docker exec -i -e MYSQL_PWD="$password" "$container" mariadb -u "$username" "$database"
    else
        docker exec -i -e MYSQL_PWD="$password" "$container" mariadb -u "$username"
    fi
}

# resolve_db_password container username env_key outvar [env_file]
# Tries env_file first, then container MYSQL_PASSWORD env as fallback.
resolve_db_password() {
    local container="$1"
    local username="$2"
    local env_key="$3"
    local password_var_name="$4"
    local env_file="${5:-}"
    local env_password="" container_password=""

    if [[ -n "$env_file" && -f "$env_file" ]]; then
        env_password=$(get_env_var "$env_key" "$env_file")
    fi
    printf -v "$password_var_name" '%s' "$env_password"

    if [[ -n "$env_password" ]] && test_mariadb_connection "$container" "$username" "$env_password"; then
        return 0
    fi

    container_password=$(get_container_mariadb_password "$container")
    if [[ -n "$container_password" ]] && test_mariadb_connection "$container" "$username" "$container_password"; then
        if [[ -n "$env_password" && "$env_password" != "$container_password" ]]; then
            log WARN "$env_key in ${env_file:-config} does not match the running container"
            log WARN "Using container environment password instead"
        elif [[ -z "$env_password" ]]; then
            log WARN "$env_key not found in ${env_file:-config}; using container environment password"
        fi
        printf -v "$password_var_name" '%s' "$container_password"
        return 0
    fi

    return 1
}

# ======================
# COMPOSE HELPERS
# ======================

# Run docker compose in a specific directory.
dc() {
    local dir="$1"
    shift
    (cd "$dir" && docker compose "$@")
}

# Return the container ID for a compose service (empty if not running).
dc_container_id() {
    local dir="$1"
    local service="$2"
    dc "$dir" ps -q "$service" 2>/dev/null || true
}

