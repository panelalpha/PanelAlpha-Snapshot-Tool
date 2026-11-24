# ======================
# SNAPSHOT METADATA
# ======================

create_snapshot_metadata() {
    local snap_dir="$1"
    local total_size="${2:-unknown}"
    local duration="${3:-unknown}"

    local components=""
    case "$INSTALLATION_TYPE" in
        multi-server)
            components="- Database: panelalpha (API, from database-api)
- Database: matomo (from database-matomo, panels older than 1.8.5 only)
- Volumes: api-storage, database-api-data, redis-data, matomo (${PANEL_DIR} project)
- Config: .env, .env-api, docker-compose.yml, packages/ (with vendor/), version
- SSL: crt/, /etc/letsencrypt, other files from SSL_CERT_FULLCHAIN/SSL_CERT_PRIVKEY"
            ;;
        engine)
            components="- Database: core (from database-core)
- Database: users all databases (from database-users)
- Volumes: core-storage, database-core-data, database-users-data (${ENGINE_DIR} project)
- Config: .env/.env-core, docker-compose.yml
- Users: ${ENGINE_DIR}/users/
- Home: /home/"
            ;;
        single-server)
            components="- Engine database: core (from database-core)
- Engine database: users all databases (from database-users)
- Engine volumes: core-storage, database-core-data, database-users-data
- Engine config: .env/.env-core, docker-compose.yml
- Panel database: panel schema (from database-core, app-lite credentials)
- Panel config: app-lite .env, docker-compose.yml
- Panel data: app-lite/data/api-storage/
- Users: ${ENGINE_DIR}/users/
- Home: /home/"
            ;;
        *)
            components="- Unknown profile"
            ;;
    esac

    cat > "${snap_dir}/snapshot-info.txt" << EOF
PanelAlpha Snapshot Information
========================================
Created: $(date)
Hostname: $(hostname)
Server IP: $(hostname -I 2>/dev/null | awk '{print $1}' || echo unknown)
Script Version: $SCRIPT_VERSION
Total Size: $total_size
Creation Time: ${duration}s
Repository: ${RESTIC_REPOSITORY:-unknown}
Tag: $BACKUP_TAG
Installation Type: $INSTALLATION_TYPE
Panel Version: $(read_panel_version)

Components Included:
$components

Security:
- All data encrypted with AES-256
- Repository password protected
- Temporary files securely removed

Recovery Instructions:
1. Install pasnap tool on target server
2. Configure repository with same credentials: $0 --setup
3. Restore: sudo $0 --restore <snapshot-id>
EOF
}

# ======================
# SNAPSHOT CLEANUP
# ======================

cleanup_temp_dir() {
    if [[ -n "${BACKUP_TEMP_DIR:-}" && -d "$BACKUP_TEMP_DIR" ]]; then
        log DEBUG "Cleaning temp dir: $BACKUP_TEMP_DIR"
        rm -rf "$BACKUP_TEMP_DIR" 2>/dev/null || log WARN "Could not remove temp dir: $BACKUP_TEMP_DIR"
    fi
}

# ======================
# PROFILE: MULTI-SERVER SNAPSHOT
# ======================

snapshot_profile_multi_server() {
    local snap_dir="$1"

    log INFO "--- Multi-server snapshot profile ---"
    mkdir -p "$snap_dir/databases" "$snap_dir/volumes" "$snap_dir/config/panel"

    local env_file="$PANEL_DIR/.env"
    local env_api_file="$PANEL_DIR/.env-api"
    local api_container
    api_container=$(dc_container_id "$PANEL_DIR" "database-api")

    if [[ -z "$api_container" ]]; then
        log ERROR "database-api container not found in $PANEL_DIR (required)"
        return 1
    fi

    # Resolve password: try .env first, then .env-api
    local api_password=""
    local password_resolved=false

    if resolve_db_password "$api_container" "panelalpha" "API_MYSQL_PASSWORD" api_password "$env_file"; then
        password_resolved=true
    elif [[ -f "$env_api_file" ]] && \
         resolve_db_password "$api_container" "panelalpha" "API_MYSQL_PASSWORD" api_password "$env_api_file"; then
        password_resolved=true
        log INFO "Using API_MYSQL_PASSWORD from .env-api"
    fi

    if [[ "$password_resolved" == "false" ]]; then
        log ERROR "Cannot connect to database-api (checked .env and .env-api)"
        return 1
    fi

    # Database dump
    dump_mariadb_database "$PANEL_DIR" "database-api" "panelalpha" "$api_password" "panelalpha" \
        "$snap_dir/databases/panelalpha-api.sql" || return 1

    # Docker volumes
    for vol in "api-storage" "database-api-data" "redis-data"; do
        snapshot_docker_volume "$PANEL_DIR" "$vol" "$snap_dir/volumes/${vol}.tar.gz" "true" || return 1
    done

    # Panels older than 1.8.5 run Matomo with its own database
    local matomo_container
    matomo_container=$(dc_container_id "$PANEL_DIR" "database-matomo")
    if [[ -n "$matomo_container" ]]; then
        local matomo_password=""
        if ! resolve_db_password "$matomo_container" "matomo" "MATOMO_MYSQL_PASSWORD" matomo_password "$env_file"; then
            log ERROR "Cannot connect to database-matomo (checked MATOMO_MYSQL_PASSWORD in .env)"
            return 1
        fi
        dump_mariadb_database "$PANEL_DIR" "database-matomo" "matomo" "$matomo_password" "matomo" \
            "$snap_dir/databases/matomo.sql" || return 1
        snapshot_docker_volume "$PANEL_DIR" "matomo" "$snap_dir/volumes/matomo.tar.gz" "false" || return 1
    fi

    # Config files
    for f in ".env" ".env-api" "docker-compose.yml"; do
        [[ -f "$PANEL_DIR/$f" ]] && cp "$PANEL_DIR/$f" "$snap_dir/config/panel/" 2>/dev/null || true
    done

    verify_panel_2fa_snapshot "$PANEL_DIR" "database-api" "panelalpha" "$api_password" \
        "panelalpha" "$snap_dir/config/panel"

    # packages/ directory, with vendor/: restore lays it over the installed panel,
    # so the code must be complete and match the restored database.
    if [[ -d "$PANEL_DIR/packages" ]]; then
        log INFO "Snapshotting packages directory..."
        if ! snapshot_path "$PANEL_DIR/packages" "$snap_dir/config/panel/packages" "true"; then
            log WARN "packages snapshot may be incomplete"
        fi
    else
        log INFO "No packages directory found - skipping"
    fi
    [[ -f "$PANEL_DIR/version" ]] && cp "$PANEL_DIR/version" "$snap_dir/config/panel/" 2>/dev/null || true

    snapshot_panel_ssl "$snap_dir"

    log INFO "Multi-server profile snapshot complete"
    return 0
}

# nginx mounts SSL_CERT_FULLCHAIN and SSL_CERT_PRIVKEY from the panel .env. Keep
# crt/ (installer default), /etc/letsencrypt and any other file .env points at.
snapshot_panel_ssl() {
    local snap_dir="$1"

    if [[ -d "$PANEL_DIR/crt" ]]; then
        log INFO "Snapshotting $PANEL_DIR/crt..."
        mkdir -p "$snap_dir/config/panel"
        cp -a "$PANEL_DIR/crt" "$snap_dir/config/panel/" || log WARN "crt/ snapshot incomplete"
    fi

    if [[ -d "/etc/letsencrypt" ]]; then
        log INFO "Snapshotting /etc/letsencrypt..."
        mkdir -p "$snap_dir/config/ssl"
        cp -a /etc/letsencrypt "$snap_dir/config/ssl/" || log WARN "SSL certificate snapshot incomplete"
    fi

    local key path
    for key in SSL_CERT_FULLCHAIN SSL_CERT_PRIVKEY; do
        path=$(resolve_panel_path "$(get_env_var "$key" "$PANEL_DIR/.env")")
        [[ -z "$path" ]] && continue
        case "$path" in
            "$PANEL_DIR"/crt/*|/etc/letsencrypt/*) continue ;;
        esac
        if [[ -f "$path" ]]; then
            mkdir -p "$snap_dir/config/ssl/files$(dirname "$path")"
            cp -L "$path" "$snap_dir/config/ssl/files$path" || log WARN "Could not snapshot $key file: $path"
        else
            log WARN "$key points to a missing file: $path"
        fi
    done
}

# Save the root crontab. The restore puts back only its PanelAlpha jobs
# (for example letsencrypt-renew.sh), see restore_root_crontab.
snapshot_root_crontab() {
    local snap_dir="$1"
    mkdir -p "$snap_dir/config"
    if crontab -l > "$snap_dir/config/crontab-root.txt" 2>/dev/null; then
        log INFO "Root crontab saved ($(grep -c "/opt/panelalpha/" "$snap_dir/config/crontab-root.txt" || true) PanelAlpha jobs)"
    else
        rm -f "$snap_dir/config/crontab-root.txt"
        log INFO "No root crontab - skipping"
    fi
}

# ======================
# PROFILE: ENGINE SNAPSHOT
# ======================

snapshot_profile_engine() {
    local snap_dir="$1"

    log INFO "--- Engine snapshot profile ---"
    mkdir -p "$snap_dir/databases" "$snap_dir/volumes" "$snap_dir/config/engine"

    # Resolve env file
    local env_file=""
    if [[ -f "$ENGINE_DIR/.env" ]]; then
        env_file="$ENGINE_DIR/.env"
    elif [[ -f "$ENGINE_DIR/.env-core" ]]; then
        env_file="$ENGINE_DIR/.env-core"
    else
        env_file="$ENGINE_DIR/.env"
    fi

    # --- Core database ---
    local core_container
    core_container=$(dc_container_id "$ENGINE_DIR" "database-core")
    if [[ -z "$core_container" ]]; then
        log ERROR "database-core container not found in $ENGINE_DIR (required)"
        return 1
    fi
    local core_password=""
    if ! resolve_db_password "$core_container" "core" "CORE_MYSQL_PASSWORD" core_password "$env_file"; then
        log ERROR "Cannot connect to database-core"
        return 1
    fi
    dump_mariadb_database "$ENGINE_DIR" "database-core" "core" "$core_password" "core" \
        "$snap_dir/databases/panelalpha-core.sql" || return 1

    # --- Users database (all databases) ---
    local users_container
    users_container=$(dc_container_id "$ENGINE_DIR" "database-users")
    if [[ -z "$users_container" ]]; then
        log ERROR "database-users container not found in $ENGINE_DIR (required)"
        return 1
    fi
    local users_password=""
    if ! resolve_db_password "$users_container" "root" "USERS_MYSQL_ROOT_PASSWORD" users_password "$env_file"; then
        log ERROR "Cannot connect to database-users"
        return 1
    fi
    dump_mariadb_all "$ENGINE_DIR" "database-users" "root" "$users_password" \
        "$snap_dir/databases/panelalpha-users.sql" "true" || return 1

    # --- Docker volumes ---
    for vol in "core-storage" "database-core-data" "database-users-data"; do
        snapshot_docker_volume "$ENGINE_DIR" "$vol" "$snap_dir/volumes/${vol}.tar.gz" "true" || return 1
    done

    # --- Config files ---
    for f in ".env" ".env-core" "docker-compose.yml"; do
        [[ -f "$ENGINE_DIR/$f" ]] && cp "$ENGINE_DIR/$f" "$snap_dir/config/engine/" 2>/dev/null || true
    done

    # --- users/ directory ---
    if [[ -d "$ENGINE_DIR/users" ]]; then
        local users_count
        users_count=$(find "$ENGINE_DIR/users" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l || echo "0")
        if [[ $users_count -gt 0 ]]; then
            log INFO "Snapshotting users directory..."
            mkdir -p "$snap_dir/users"
            # Full copy: these are customer project files, nothing here is safe to skip.
            if ! snapshot_path "$ENGINE_DIR/users" "$snap_dir/users" "all"; then
                log WARN "Users directory snapshot may be incomplete"
            else
                local users_size
                users_size=$(du -sh "$snap_dir/users" 2>/dev/null | cut -f1 || echo "0")
                log INFO "Users directory snapshotted ($users_size)"
            fi
        else
            log INFO "users/ directory is empty - skipping"
        fi
    else
        log INFO "No users directory at $ENGINE_DIR/users - skipping"
    fi

    # --- /home directory ---
    if [[ -d "/home" ]]; then
        log INFO "Snapshotting /home (may take a while)..."
        mkdir -p "$snap_dir/home"
        local rsync_exit=0
        if command -v rsync &>/dev/null; then
            timeout "${USERS_HOME_SNAPSHOT_TIMEOUT}" \
                rsync -a --numeric-ids /home/ "$snap_dir/home/" 2>/dev/null || rsync_exit=$?
            if [[ $rsync_exit -eq 0 || $rsync_exit -eq 23 || $rsync_exit -eq 24 ]]; then
                local home_size
                home_size=$(du -sh "$snap_dir/home" 2>/dev/null | cut -f1 || echo "0")
                log INFO "/home snapshotted ($home_size)"
                [[ $rsync_exit -ne 0 ]] && log WARN "/home snapshot may be incomplete (rsync exit $rsync_exit)"
            else
                log WARN "/home rsync failed (exit $rsync_exit), trying cp fallback..."
                cp -a /home/. "$snap_dir/home/" 2>/dev/null || log WARN "/home snapshot may be incomplete"
            fi
        else
            cp -a /home/. "$snap_dir/home/" 2>/dev/null || log WARN "/home snapshot may be incomplete"
        fi
    else
        log WARN "/home directory not found - skipping"
    fi

    log INFO "Engine profile snapshot complete"
    return 0
}

# ======================
# PROFILE: SINGLE-SERVER SNAPSHOT
# ======================

snapshot_profile_single_server() {
    local snap_dir="$1"

    log INFO "--- Single-server snapshot profile ---"

    # Engine scope first
    snapshot_profile_engine "$snap_dir" || return 1

    # App-lite scope
    log INFO "--- App-lite scope ---"
    mkdir -p "$snap_dir/databases" "$snap_dir/config/panel"

    local applite_env="$PANEL_DIR/.env"

    if [[ ! -f "$applite_env" ]]; then
        log ERROR "App-lite .env not found: $applite_env"
        return 1
    fi

    local panel_db="" panel_user="" panel_password=""
    panel_db=$(get_env_var "DB_DATABASE" "$applite_env")
    panel_user=$(get_env_var "DB_USERNAME" "$applite_env")
    panel_password=$(get_env_var "DB_PASSWORD" "$applite_env")

    if [[ -z "$panel_user" || -z "$panel_password" || -z "$panel_db" ]]; then
        log ERROR "DB_DATABASE/DB_USERNAME/DB_PASSWORD not found in $applite_env"
        return 1
    fi

    # Panel DB is stored in database-core (ENGINE_DIR compose project)
    local core_container
    core_container=$(dc_container_id "$ENGINE_DIR" "database-core")
    if [[ -z "$core_container" ]]; then
        log ERROR "database-core container not found (required for panel DB dump)"
        return 1
    fi

    if ! test_mariadb_connection "$core_container" "$panel_user" "$panel_password"; then
        log ERROR "Cannot connect to database-core with panel credentials (user: $panel_user)"
        log ERROR "Check DB_USERNAME/DB_PASSWORD in $applite_env"
        return 1
    fi

    # Dump panel schema from database-core using app-lite credentials
    dump_mariadb_database "$ENGINE_DIR" "database-core" "$panel_user" "$panel_password" "$panel_db" \
        "$snap_dir/databases/panelalpha-panel.sql" || return 1

    # App-lite config files
    for f in ".env" "docker-compose.yml"; do
        [[ -f "$PANEL_DIR/$f" ]] && cp "$PANEL_DIR/$f" "$snap_dir/config/panel/" 2>/dev/null || true
    done

    verify_panel_2fa_snapshot "$ENGINE_DIR" "database-core" "$panel_user" "$panel_password" \
        "$panel_db" "$snap_dir/config/panel"

    # App-lite data/api-storage path snapshot
    if [[ -d "$PANEL_DIR/data/api-storage" ]]; then
        log INFO "Snapshotting app-lite data/api-storage..."
        mkdir -p "$snap_dir/config/panel/data"
        if ! snapshot_path "$PANEL_DIR/data/api-storage" "$snap_dir/config/panel/data/api-storage"; then
            log WARN "app-lite data/api-storage snapshot may be incomplete"
        else
            local storage_size
            storage_size=$(du -sh "$snap_dir/config/panel/data/api-storage" 2>/dev/null | cut -f1 || echo "0")
            log INFO "app-lite data/api-storage snapshotted ($storage_size)"
        fi
    else
        log INFO "No data/api-storage at $PANEL_DIR/data/api-storage - skipping"
    fi

    log INFO "Single-server profile snapshot complete"
    return 0
}

