# ======================
# RESTORE HELPERS
# ======================

resolve_snapshot() {
    local input="$1"

    if [[ "$input" == "latest" ]]; then
        SNAPSHOT_ID=$(restic snapshots --repo "$RESTIC_REPOSITORY" --tag "$BACKUP_TAG" \
            --json 2>/dev/null | jq -r 'sort_by(.time) | last | .short_id // empty' \
            2>/dev/null || echo "")

        if [[ -z "$SNAPSHOT_ID" || "$SNAPSHOT_ID" == "null" ]]; then
            SNAPSHOT_ID=$(restic snapshots --repo "$RESTIC_REPOSITORY" --tag "panelalpha" \
                --json 2>/dev/null | jq -r 'sort_by(.time) | last | .short_id // empty' \
                2>/dev/null || echo "")
        fi

        if [[ -z "$SNAPSHOT_ID" || "$SNAPSHOT_ID" == "null" ]]; then
            SNAPSHOT_ID=$(restic snapshots --repo "$RESTIC_REPOSITORY" \
                --json 2>/dev/null | jq -r 'sort_by(.time) | last | .short_id // empty' \
                2>/dev/null || echo "")
        fi

        if [[ -z "$SNAPSHOT_ID" || "$SNAPSHOT_ID" == "null" ]]; then
            log ERROR "No snapshots found in repository"
            log ERROR "Create a snapshot first: $0 --snapshot"
            exit 1
        fi
        local snapshot_origin=""
        snapshot_origin=$(restic snapshots --repo "$RESTIC_REPOSITORY" --json "$SNAPSHOT_ID" 2>/dev/null | \
            jq -r '.[0] | "taken \(.time) on \(.hostname)"' 2>/dev/null || echo "")
        log INFO "Latest snapshot: $SNAPSHOT_ID ${snapshot_origin}"
    else
        SNAPSHOT_ID="$input"
    fi

    if ! restic snapshots --repo "$RESTIC_REPOSITORY" --json 2>/dev/null | \
        jq -r '.[].short_id' | grep -q "^${SNAPSHOT_ID}$" 2>/dev/null; then
        log ERROR "Snapshot $SNAPSHOT_ID not found"
        log INFO "Available snapshots:"
        restic snapshots --repo "$RESTIC_REPOSITORY" --compact 2>/dev/null || true
        exit 1
    fi
}

wait_for_database_containers() {
    local compose_dir="$1"
    shift
    local services=("$@")

    log INFO "Waiting for database containers to be ready: ${services[*]}"
    local max_attempts=120
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        local all_ready=true
        for svc in "${services[@]}"; do
            local cid
            cid=$(dc_container_id "$compose_dir" "$svc")
            # Ping over TCP: during first start the image runs a temporary server
            # with networking off, and a socket ping would report it as ready.
            if [[ -z "$cid" ]] || ! docker exec "$cid" \
                mariadb-admin --protocol=tcp -h 127.0.0.1 ping --silent &>/dev/null; then
                all_ready=false
                break
            fi
        done

        if [[ "$all_ready" == "true" ]]; then
            log INFO "All database containers ready"
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ $((attempt % 15)) -eq 0 ]]; then
            log INFO "Still waiting... ($attempt/$max_attempts)"
        fi
        sleep 2
    done

    log ERROR "Timeout waiting for database containers"
    for svc in "${services[@]}"; do
        local cid
        cid=$(dc_container_id "$compose_dir" "$svc") || true
        [[ -n "$cid" ]] && docker logs "$cid" --tail 10 2>/dev/null || true
    done
    return 1
}

setup_database_user() {
    local container="$1"
    local username="$2"
    local password="$3"

    log INFO "Setting up database user: $username"
    sleep 3

    if test_mariadb_connection "$container" "$username" "$password"; then
        log INFO "User $username already exists and can log in"
        return 0
    fi

    log INFO "Creating user $username..."

    # Try root without password (fresh container default)
    if docker exec "$container" mariadb -e "
        CREATE USER IF NOT EXISTS '$username'@'%' IDENTIFIED BY '$password';
        CREATE USER IF NOT EXISTS '$username'@'localhost' IDENTIFIED BY '$password';
        GRANT ALL PRIVILEGES ON \`$username\`.* TO '$username'@'%';
        GRANT ALL PRIVILEGES ON \`$username\`.* TO '$username'@'localhost';
        FLUSH PRIVILEGES;
    " 2>/dev/null; then
        log INFO "User $username created (root without password)"
    else
        # Try with root password from container environment
        local root_pw=""
        root_pw=$(docker exec "$container" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || true)
        [[ -z "$root_pw" ]] && \
            root_pw=$(docker exec "$container" printenv MARIADB_ROOT_PASSWORD 2>/dev/null || true)

        if [[ -n "$root_pw" ]] && mariadb_exec "$container" "root" "$root_pw" -e "
            CREATE USER IF NOT EXISTS '$username'@'%' IDENTIFIED BY '$password';
            GRANT ALL PRIVILEGES ON \`$username\`.* TO '$username'@'%';
            FLUSH PRIVILEGES;
        " 2>/dev/null; then
            log INFO "User $username created (root with password)"
        else
            log ERROR "Failed to create user $username"
            return 1
        fi
    fi

    if test_mariadb_connection "$container" "$username" "$password"; then
        log INFO "User $username login verified"
        return 0
    else
        log ERROR "User $username cannot log in after creation"
        return 1
    fi
}

restore_single_database() {
    local db_name="$1"
    local compose_dir="$2"
    local service_name="$3"
    local db_user="$4"
    local db_password="$5"
    local sql_file="$6"

    log INFO "Restoring database '$db_name' from $(basename "$sql_file")..."

    local container
    container=$(dc_container_id "$compose_dir" "$service_name")
    if [[ -z "$container" ]]; then
        log ERROR "Container for $service_name not found"
        return 1
    fi

    if [[ ! -f "$sql_file" || ! -r "$sql_file" ]]; then
        log ERROR "SQL file not found or unreadable: $sql_file"
        return 1
    fi

    # Setup user if it is not root
    if [[ "$db_user" != "root" ]]; then
        setup_database_user "$container" "$db_user" "$db_password" || return 1
    fi

    # Drop and recreate target database
    if ! mariadb_exec "$container" "$db_user" "$db_password" \
        -e "DROP DATABASE IF EXISTS \`$db_name\`; \
            CREATE DATABASE \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        2>/dev/null; then
        mariadb_exec "$container" "$db_user" "$db_password" \
            -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
            2>/dev/null || { log ERROR "Cannot create database $db_name"; return 1; }
    fi

    # Import SQL dump
    local import_ok=false err_file
    err_file=$(mktemp)
    if [[ "$sql_file" == *.gz ]]; then
        if gunzip -c "$sql_file" | \
            mariadb_exec_stdin "$container" "$db_user" "$db_password" "$db_name" 2>"$err_file"; then
            import_ok=true
        fi
    else
        if mariadb_exec_stdin "$container" "$db_user" "$db_password" "$db_name" \
            < "$sql_file" 2>"$err_file"; then
            import_ok=true
        fi
    fi

    if [[ "$import_ok" == "false" ]]; then
        log ERROR "Failed to import database $db_name"
        log_stderr_tail "$err_file"
        rm -f "$err_file"
        return 1
    fi
    rm -f "$err_file"

    local table_count
    table_count=$(mariadb_exec "$container" "$db_user" "$db_password" \
        -e "USE \`$db_name\`; SHOW TABLES;" 2>/dev/null | wc -l || echo "0")
    if [[ $table_count -gt 1 ]]; then
        log INFO "Database $db_name restored ($((table_count - 1)) tables)"
    else
        log WARN "Database $db_name may be empty after import"
    fi

    return 0
}

restore_volume() {
    local compose_dir="$1"
    local volume_suffix="$2"
    local tar_file="$3"

    if [[ ! -f "$tar_file" ]]; then
        log INFO "Volume archive not found, skipping: $(basename "$tar_file")"
        return 0
    fi

    local project_name
    project_name=$(basename "$compose_dir")
    local full_volume_name="${project_name}_${volume_suffix}"
    local tar_dir
    tar_dir=$(dirname "$tar_file")
    local tar_base
    tar_base=$(basename "$tar_file")

    log INFO "Restoring volume: $volume_suffix"
    docker volume create "$full_volume_name" 2>/dev/null || true

    if ! docker run --rm \
        -v "${full_volume_name}:/target" \
        -v "${tar_dir}:/backup:ro" \
        ubuntu:20.04 \
        tar xzf "/backup/${tar_base}" -C /target 2>/dev/null; then
        log ERROR "Failed to restore volume $volume_suffix"
        return 1
    fi

    log INFO "Volume $volume_suffix restored"
    return 0
}

clean_db_volumes() {
    local compose_dir="$1"
    shift
    local volumes=("$@")
    local project_name
    project_name=$(basename "$compose_dir")

    for vol in "${volumes[@]}"; do
        local full_name="${project_name}_${vol}"
        if docker volume inspect "$full_name" &>/dev/null; then
            log INFO "Removing database volume: $full_name"
            docker volume rm "$full_name" 2>/dev/null || log WARN "Could not remove $full_name"
        fi
    done
}

update_system_settings() {
    [[ "$INSTALLATION_TYPE" == "multi-server" ]] || return 0

    log INFO "Updating system settings for current server..."
    local env_file="$PANEL_DIR/.env"
    local container
    container=$(dc_container_id "$PANEL_DIR" "database-api")
    if [[ -z "$container" ]]; then
        log WARN "database-api not running, skipping system settings update"
        return 0
    fi

    local api_password=""
    if ! resolve_db_password "$container" "panelalpha" "API_MYSQL_PASSWORD" api_password "$env_file"; then
        log WARN "Cannot connect for system settings update"
        return 0
    fi

    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

    mariadb_exec "$container" "panelalpha" "$api_password" panelalpha \
        -e "UPDATE system_settings SET value='$server_ip' WHERE name='host_ip_address';" \
        2>/dev/null && log INFO "Updated host_ip_address: $server_ip" || \
        log WARN "Could not update host_ip_address"

    # trusted_hosts stays as restored. The installer sets it to "*" and admins add
    # their panel domains to it; replacing it breaks login on those domains.
}

# Keep an env assignment, or append it. Value must not contain newlines.
upsert_env_var() {
    local key="$1"
    local value="$2"
    local file="$3"

    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# When SANCTUM_STATEFUL_DOMAINS is set, admin login by IP needs the address in it.
# Do not also put that IP in trusted_hosts: SetSessionDomain would set the
# session cookie Domain to the raw IP, and browsers drop that cookie.
sync_sanctum_stateful_domains() {
    local env_file="$1"
    if [[ ! -f "$env_file" ]]; then
        log WARN "No $env_file — skipping Sanctum stateful domains"
        return 0
    fi

    local hostname_fqdn ip public_ip
    hostname_fqdn=$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    public_ip=$(curl -4 -fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)

    local current=""
    current=$(get_env_var "SANCTUM_STATEFUL_DOMAINS" "$env_file")

    # Empty is the installer default: the panel then takes the stateful host from
    # each request (trusted_hosts, panel URLs). Setting a list here would turn
    # that off and break login on every panel domain that is not in the list.
    if [[ -z "$current" ]]; then
        log INFO "SANCTUM_STATEFUL_DOMAINS is empty in $env_file - panel sets it per request, leaving it unchanged"
        return 0
    fi

    local candidates=()
    local part extra
    if [[ -n "$current" ]]; then
        IFS=',' read -r -a candidates <<< "$current"
    fi
    for extra in "$hostname_fqdn" "${hostname_fqdn}:8443" "$ip" "${ip}:8443" "$public_ip" "${public_ip}:8443"; do
        [[ -n "$extra" && "$extra" != ":8443" ]] && candidates+=("$extra")
    done

    local merged="" seen=" "
    for part in "${candidates[@]}"; do
        part=$(printf '%s' "$part" | tr -d '[:space:]')
        [[ -z "$part" ]] && continue
        if [[ "$seen" != *" ${part} "* ]]; then
            seen="${seen}${part} "
            if [[ -n "$merged" ]]; then
                merged="${merged},${part}"
            else
                merged="$part"
            fi
        fi
    done

    if [[ -z "$merged" ]]; then
        log WARN "Could not determine hosts for Sanctum stateful domains"
        return 0
    fi

    upsert_env_var "SANCTUM_STATEFUL_DOMAINS" "$merged" "$env_file"
    log INFO "Sanctum stateful domains updated in $env_file"
}

# ======================
# RESTORE CONFIG HELPERS
# ======================

_restore_config_engine_dir() {
    local data_dir="$1"
    local target_dir="$2"

    local config_engine="$data_dir/config/engine"
    if [[ ! -d "$config_engine" ]]; then
        log WARN "No engine config directory in snapshot"
        return 0
    fi

    for f in ".env" ".env-core" "docker-compose.yml"; do
        if [[ -f "$config_engine/$f" ]]; then
            cp "$config_engine/$f" "$target_dir/" 2>/dev/null && \
                log INFO "Restored $f to $target_dir" || \
                log WARN "Could not restore $f"
        fi
    done
}

_restore_config_panel_dir() {
    local data_dir="$1"
    local target_dir="$2"
    local with_packages="${3:-true}"

    local config_panel="$data_dir/config/panel"
    if [[ ! -d "$config_panel" ]]; then
        log WARN "No panel config directory in snapshot"
        return 0
    fi

    for f in ".env" ".env-api" "docker-compose.yml"; do
        if [[ -f "$config_panel/$f" ]]; then
            cp "$config_panel/$f" "$target_dir/" 2>/dev/null && \
                log INFO "Restored $f to $target_dir" || \
                log WARN "Could not restore $f"
        fi
    done

    if [[ "$with_packages" == "true" ]] && [[ -d "$config_panel/packages" ]]; then
        log INFO "Restoring packages directory..."
        if command -v rsync &>/dev/null; then
            rsync -a "$config_panel/packages/" "$target_dir/packages/" 2>/dev/null || \
                cp -r "$config_panel/packages" "$target_dir/" 2>/dev/null || \
                log WARN "packages restore incomplete"
        else
            cp -r "$config_panel/packages" "$target_dir/" 2>/dev/null || \
                log WARN "packages restore incomplete"
        fi
    fi

    _restore_panel_ssl "$data_dir" "$target_dir"
}

# Restore what snapshot_panel_ssl saved: crt/, /etc/letsencrypt and other cert files.
_restore_panel_ssl() {
    local data_dir="$1"
    local target_dir="$2"
    local config_panel="$data_dir/config/panel"
    local config_ssl="$data_dir/config/ssl"

    if [[ -d "$config_panel/crt" ]]; then
        log INFO "Restoring $target_dir/crt..."
        mkdir -p "$target_dir/crt"
        cp -a "$config_panel/crt/." "$target_dir/crt/" || log WARN "crt/ restore incomplete"
    fi

    if [[ -d "$config_ssl/letsencrypt" ]]; then
        log INFO "Restoring /etc/letsencrypt..."
        mkdir -p /etc/letsencrypt
        cp -a "$config_ssl/letsencrypt/." /etc/letsencrypt/ || log WARN "SSL restore incomplete"
    fi

    if [[ -d "$config_ssl/files" ]]; then
        local file dest
        while IFS= read -r -d '' file; do
            dest="${file#"$config_ssl/files"}"
            mkdir -p "$(dirname "$dest")"
            if cp -p "$file" "$dest"; then
                log INFO "Restored certificate file $dest"
            else
                log WARN "Could not restore certificate file $dest"
            fi
        done < <(find "$config_ssl/files" -type f -print0)
    fi
}

# nginx mounts SSL_CERT_FULLCHAIN and SSL_CERT_PRIVKEY from the panel .env.
# Docker turns a missing file into an empty directory and nginx does not start.
check_panel_ssl_files() {
    local key path missing=false
    for key in SSL_CERT_FULLCHAIN SSL_CERT_PRIVKEY; do
        path=$(resolve_panel_path "$(get_env_var "$key" "$PANEL_DIR/.env")")
        if [[ -n "$path" && ! -f "$path" ]]; then
            log ERROR "$key points to a missing file: $path"
            missing=true
        fi
    done
    if [[ "$missing" == "true" ]]; then
        log ERROR "nginx will not start until these files exist. Put the certificate there or change"
        log ERROR "SSL_CERT_FULLCHAIN/SSL_CERT_PRIVKEY in $PANEL_DIR/.env, then run: cd $PANEL_DIR && docker compose up -d"
        return 1
    fi
    return 0
}

# Add the PanelAlpha jobs from the snapshot's root crontab that this server lacks.
# Other lines stay out: they belong to the old server. The tool's own daily
# snapshot is left to --cron install, because its path may differ here.
restore_root_crontab() {
    local data_dir="$1"
    local saved="$data_dir/config/crontab-root.txt"
    [[ -f "$saved" ]] || return 0

    local current line added=0
    current=$(crontab -l 2>/dev/null || true)
    while IFS= read -r line; do
        [[ "$line" == *"/opt/panelalpha/"* ]] || continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *"pasnap.sh"* ]] && continue
        grep -qxF -- "$line" <<< "$current" && continue
        current=$(printf '%s\n%s' "$current" "$line")
        log INFO "Adding cron job from snapshot: $line"
        added=$((added + 1))
    done < "$saved"

    if [[ $added -gt 0 ]]; then
        printf '%s\n' "$current" | sed '/./,$!d' | crontab - || log WARN "Could not update the root crontab"
    fi
    if grep -q "pasnap.sh" "$saved" && ! crontab -l 2>/dev/null | grep -q "pasnap.sh"; then
        log WARN "Daily snapshots are not scheduled on this server. Run: $0 --cron install"
    fi
}

_restore_users_and_home() {
    local data_dir="$1"

    # users/ directory
    if [[ -d "$data_dir/users" ]]; then
        log INFO "Restoring users directory to $ENGINE_DIR/users..."
        mkdir -p "$ENGINE_DIR/users"
        if command -v rsync &>/dev/null; then
            rsync -a "$data_dir/users/" "$ENGINE_DIR/users/" 2>/dev/null || \
                cp -a "$data_dir/users/." "$ENGINE_DIR/users/" 2>/dev/null || \
                log WARN "users restore may be incomplete"
        else
            cp -a "$data_dir/users/." "$ENGINE_DIR/users/" 2>/dev/null || \
                log WARN "users restore may be incomplete"
        fi
    else
        log INFO "No users/ directory in snapshot - skipping"
    fi

    # /home directory
    if [[ -d "$data_dir/home" ]]; then
        log INFO "Restoring /home..."
        mkdir -p /home
        if command -v rsync &>/dev/null; then
            rsync -a --numeric-ids "$data_dir/home/" /home/ 2>/dev/null || \
                cp -a "$data_dir/home/." /home/ 2>/dev/null || \
                log WARN "/home restore may be incomplete"
        else
            cp -a "$data_dir/home/." /home/ 2>/dev/null || \
                log WARN "/home restore may be incomplete"
        fi
    else
        log INFO "No home/ directory in snapshot - skipping"
    fi
}

