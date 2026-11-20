# ======================
# RESTORE PROFILES
# ======================

restore_from_snapshot() {
    local snapshot_id_input="$1"
    [[ -z "$snapshot_id_input" ]] && { log ERROR "Snapshot ID required"; exit 1; }

    log INFO "=== Restoring from Snapshot: $snapshot_id_input ==="
    check_requirements
    log_installation_banner

    resolve_snapshot "$snapshot_id_input"

    mkdir -p "$RESTORE_TEMP_DIR"
    # shellcheck disable=SC2064
    trap "rm -rf '$RESTORE_TEMP_DIR'" EXIT

    log INFO "Retrieving snapshot $SNAPSHOT_ID..."
    restic restore "$SNAPSHOT_ID" --repo "$RESTIC_REPOSITORY" --target "$RESTORE_TEMP_DIR"

    # Locate snapshot root by finding snapshot-info.txt marker
    local data_dir="" info_file=""
    info_file=$(find "$RESTORE_TEMP_DIR" -type f -name "snapshot-info.txt" 2>/dev/null | head -1 || true)
    if [[ -n "$info_file" ]]; then
        data_dir="$(dirname "$info_file")"
    else
        data_dir=$(find "$RESTORE_TEMP_DIR" -type d -name "pasnap-snapshot-*" 2>/dev/null | head -1 || true)
    fi

    if [[ -z "$data_dir" || ! -d "$data_dir" ]]; then
        log ERROR "Cannot locate snapshot data under $RESTORE_TEMP_DIR"
        log ERROR "Snapshot may be corrupted or incompatible"
        log ERROR "Contents: $(find "$RESTORE_TEMP_DIR" -maxdepth 4 2>/dev/null | head -20)"
        exit 1
    fi

    log INFO "Snapshot data found: $data_dir"
    grep "^Created:" "$data_dir/snapshot-info.txt" 2>/dev/null || true

    # Check installation type mismatch
    local snapshot_type=""
    snapshot_type=$(grep "^Installation Type:" "$data_dir/snapshot-info.txt" 2>/dev/null | \
        cut -d: -f2 | tr -d ' ' || echo "")
    if [[ -n "$snapshot_type" && "$snapshot_type" != "$INSTALLATION_TYPE" ]]; then
        log WARN "Snapshot was created on a '$snapshot_type' installation"
        log WARN "Current installation type is '$INSTALLATION_TYPE'"
        read -r -p "Continue anyway? (yes/no): " mismatch_confirm
        if [[ "$mismatch_confirm" != "yes" ]]; then
            log INFO "Restore cancelled"
            return 0
        fi
    fi

    # The restore lays the snapshot's database over the installed panel code.
    # Different versions leave the database schema and the code out of step.
    local snapshot_version="" installed_version=""
    snapshot_version=$(grep "^Panel Version:" "$data_dir/snapshot-info.txt" 2>/dev/null | \
        cut -d: -f2- | tr -d ' ' || echo "")
    installed_version=$(read_panel_version)
    if [[ -n "$snapshot_version" && -n "$installed_version" && "$snapshot_version" != "$installed_version" ]]; then
        log WARN "Snapshot was taken on panel version $snapshot_version, this server runs $installed_version"
        log WARN "Install panel version $snapshot_version on this server first, then restore"
        read -r -p "Continue anyway? (yes/no): " version_confirm
        if [[ "$version_confirm" != "yes" ]]; then
            log INFO "Restore cancelled"
            return 0
        fi
    fi

    echo ""
    log WARN "This will replace current PanelAlpha data. ALL CURRENT DATA WILL BE LOST!"
    echo ""
    read -r -p "Continue with restore? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log INFO "Restore cancelled"
        return 0
    fi

    case "$INSTALLATION_TYPE" in
        multi-server)
            _restore_multi_server  "$data_dir"
            ;;
        engine)
            _restore_engine        "$data_dir"
            ;;
        single-server)
            _restore_single_server "$data_dir"
            ;;
        *)
            log ERROR "Cannot restore: unknown installation type"
            exit 1
            ;;
    esac

    log INFO "=== Restore completed successfully ==="
    log INFO "Restored from snapshot: $SNAPSHOT_ID"
}

_restore_multi_server() {
    local data_dir="$1"

    log INFO "--- Restoring multi-server installation ---"

    # Stop all services
    log INFO "Stopping all services..."
    dc "$PANEL_DIR" down 2>/dev/null || true
    sleep 10

    # Panels older than 1.8.5 also have a Matomo database
    # redis-data is emptied, not restored: it holds the job queue, and jobs queued
    # before the snapshot have already run (sent mail, changed servers) since then.
    local db_services=("database-api") db_volumes=("database-api-data" "redis-data")
    if [[ -f "$data_dir/databases/matomo.sql" ]]; then
        db_services+=("database-matomo")
        db_volumes+=("database-matomo-data")
    fi

    # Clean only database volumes
    clean_db_volumes "$PANEL_DIR" "${db_volumes[@]}"

    # Restore panel config
    _restore_config_panel_dir "$data_dir" "$PANEL_DIR" "true"
    sync_sanctum_stateful_domains "$PANEL_DIR/.env-api"
    check_panel_ssl_files || true

    # Start only the database containers
    log INFO "Starting ${db_services[*]}..."
    dc "$PANEL_DIR" up -d "${db_services[@]}"
    wait_for_database_containers "$PANEL_DIR" "${db_services[@]}" || {
        log ERROR "${db_services[*]} failed to become ready"
        exit 1
    }

    # Restore database from SQL dump (sole source of truth for MariaDB data)
    local env_file="$PANEL_DIR/.env"
    local api_password=""
    api_password=$(get_env_var "API_MYSQL_PASSWORD" "$env_file")
    if [[ -f "$data_dir/databases/panelalpha-api.sql" ]]; then
        restore_single_database "panelalpha" "$PANEL_DIR" "database-api" "panelalpha" \
            "$api_password" "$data_dir/databases/panelalpha-api.sql" || exit 1
    else
        log WARN "panelalpha-api.sql not found in snapshot - database not restored"
    fi

    if [[ -f "$data_dir/databases/matomo.sql" ]]; then
        restore_single_database "matomo" "$PANEL_DIR" "database-matomo" "matomo" \
            "$(get_env_var "MATOMO_MYSQL_PASSWORD" "$env_file")" "$data_dir/databases/matomo.sql" || exit 1
    fi

    log WARN "Redis starts empty: queued jobs and cache from before the restore are dropped"

    # Application volumes only — do not restore database-api-data (would override SQL)
    for vol in "api-storage" "matomo"; do
        restore_volume "$PANEL_DIR" "$vol" "$data_dir/volumes/${vol}.tar.gz" || \
            log WARN "Volume $vol restore failed"
    done

    # Start all services
    log INFO "Starting all services..."
    dc "$PANEL_DIR" up -d
    sleep 20

    wait_for_database_containers "$PANEL_DIR" "database-api" || \
        log WARN "database-api not ready after full start"
    update_system_settings
    restore_root_crontab "$data_dir"

    dc "$PANEL_DIR" ps 2>/dev/null || true
    log INFO "Multi-server restore complete"
}

_restore_engine() {
    local data_dir="$1"

    log INFO "--- Restoring engine installation ---"

    # Stop all services
    log INFO "Stopping all services..."
    dc "$ENGINE_DIR" down 2>/dev/null || true
    sleep 10

    # Clean database volumes
    clean_db_volumes "$ENGINE_DIR" "database-core-data" "database-users-data"

    # Restore engine config
    _restore_config_engine_dir "$data_dir" "$ENGINE_DIR"

    # Start database containers
    log INFO "Starting database containers..."
    dc "$ENGINE_DIR" up -d database-core database-users
    wait_for_database_containers "$ENGINE_DIR" "database-core" "database-users" || {
        log ERROR "Database containers failed to start"
        exit 1
    }

    local env_file=""
    [[ -f "$ENGINE_DIR/.env" ]] && env_file="$ENGINE_DIR/.env" || env_file="$ENGINE_DIR/.env-core"

    # Restore core database
    if [[ -f "$data_dir/databases/panelalpha-core.sql" ]]; then
        local core_password=""
        core_password=$(get_env_var "CORE_MYSQL_PASSWORD" "$env_file")
        restore_single_database "core" "$ENGINE_DIR" "database-core" "core" "$core_password" \
            "$data_dir/databases/panelalpha-core.sql" || exit 1
    else
        log WARN "panelalpha-core.sql not found in snapshot"
    fi

    # Restore users databases
    local users_dump=""
    [[ -f "$data_dir/databases/panelalpha-users.sql.gz" ]] && \
        users_dump="$data_dir/databases/panelalpha-users.sql.gz"
    [[ -z "$users_dump" && -f "$data_dir/databases/panelalpha-users.sql" ]] && \
        users_dump="$data_dir/databases/panelalpha-users.sql"

    if [[ -n "$users_dump" ]]; then
        local users_password=""
        users_password=$(get_env_var "USERS_MYSQL_ROOT_PASSWORD" "$env_file")
        local users_container
        users_container=$(dc_container_id "$ENGINE_DIR" "database-users")
        if [[ -n "$users_container" && -n "$users_password" ]]; then
            log INFO "Restoring users databases from $(basename "$users_dump")..."
            if [[ "$users_dump" == *.gz ]]; then
                if gunzip -c "$users_dump" | \
                    mariadb_exec_stdin "$users_container" "root" "$users_password" 2>/dev/null; then
                    log INFO "Users databases restored"
                else
                    log ERROR "Users databases restore failed"
                    exit 1
                fi
            else
                if mariadb_exec_stdin "$users_container" "root" "$users_password" \
                    < "$users_dump" 2>/dev/null; then
                    log INFO "Users databases restored"
                else
                    log ERROR "Users databases restore failed"
                    exit 1
                fi
            fi
        else
            log WARN "Cannot restore users databases (container or password missing)"
        fi
    else
        log WARN "No users database dump found in snapshot"
    fi

    # Application volumes only — do not restore database-*-data (would override SQL)
    restore_volume "$ENGINE_DIR" "core-storage" "$data_dir/volumes/core-storage.tar.gz" || \
        log WARN "Volume core-storage restore failed"

    # Restore users/ and /home
    _restore_users_and_home "$data_dir"

    # Start all services
    log INFO "Starting all engine services..."
    dc "$ENGINE_DIR" up -d
    sleep 20

    restore_root_crontab "$data_dir"
    dc "$ENGINE_DIR" ps 2>/dev/null || true
    log INFO "Engine restore complete"
}

_restore_single_server() {
    local data_dir="$1"

    log INFO "--- Restoring single-server installation ---"

    # Stop both stacks
    log INFO "Stopping all services..."
    dc "$PANEL_DIR"  down 2>/dev/null || true
    dc "$ENGINE_DIR" down 2>/dev/null || true
    sleep 10

    # Clean engine database volumes
    clean_db_volumes "$ENGINE_DIR" "database-core-data" "database-users-data"

    # Restore configs
    _restore_config_engine_dir "$data_dir" "$ENGINE_DIR"
    _restore_config_panel_dir  "$data_dir" "$PANEL_DIR" "false"
    sync_sanctum_stateful_domains "$PANEL_DIR/.env"

    # Start engine database containers
    log INFO "Starting engine database containers..."
    dc "$ENGINE_DIR" up -d database-core database-users
    wait_for_database_containers "$ENGINE_DIR" "database-core" "database-users" || {
        log ERROR "Engine database containers failed to start"
        exit 1
    }

    local env_file=""
    [[ -f "$ENGINE_DIR/.env" ]] && env_file="$ENGINE_DIR/.env" || env_file="$ENGINE_DIR/.env-core"

    # Restore engine core database
    if [[ -f "$data_dir/databases/panelalpha-core.sql" ]]; then
        local core_password=""
        core_password=$(get_env_var "CORE_MYSQL_PASSWORD" "$env_file")
        restore_single_database "core" "$ENGINE_DIR" "database-core" "core" "$core_password" \
            "$data_dir/databases/panelalpha-core.sql" || exit 1
    else
        log WARN "panelalpha-core.sql not found in snapshot"
    fi

    # Restore engine users databases
    local users_dump=""
    [[ -f "$data_dir/databases/panelalpha-users.sql.gz" ]] && \
        users_dump="$data_dir/databases/panelalpha-users.sql.gz"
    [[ -z "$users_dump" && -f "$data_dir/databases/panelalpha-users.sql" ]] && \
        users_dump="$data_dir/databases/panelalpha-users.sql"

    if [[ -n "$users_dump" ]]; then
        local users_password=""
        users_password=$(get_env_var "USERS_MYSQL_ROOT_PASSWORD" "$env_file")
        local users_container
        users_container=$(dc_container_id "$ENGINE_DIR" "database-users")
        if [[ -n "$users_container" && -n "$users_password" ]]; then
            log INFO "Restoring users databases from $(basename "$users_dump")..."
            if [[ "$users_dump" == *.gz ]]; then
                gunzip -c "$users_dump" | \
                    mariadb_exec_stdin "$users_container" "root" "$users_password" 2>/dev/null && \
                    log INFO "Users databases restored" || log WARN "Users databases restore had errors"
            else
                mariadb_exec_stdin "$users_container" "root" "$users_password" \
                    < "$users_dump" 2>/dev/null && \
                    log INFO "Users databases restored" || log WARN "Users databases restore had errors"
            fi
        fi
    fi

    # Restore panel (app-lite) database into database-core
    if [[ -f "$data_dir/databases/panelalpha-panel.sql" ]]; then
        local applite_env="$PANEL_DIR/.env"
        local panel_db="" panel_user="" panel_password=""
        if [[ -f "$applite_env" ]]; then
            panel_db=$(get_env_var "DB_DATABASE" "$applite_env")
            panel_user=$(get_env_var "DB_USERNAME" "$applite_env")
            panel_password=$(get_env_var "DB_PASSWORD" "$applite_env")
        fi

        if [[ -n "$panel_user" && -n "$panel_password" && -n "$panel_db" ]]; then
            restore_single_database "$panel_db" "$ENGINE_DIR" "database-core" \
                "$panel_user" "$panel_password" \
                "$data_dir/databases/panelalpha-panel.sql" || \
                log WARN "Panel database restore had errors"
        else
            log WARN "Panel DB credentials missing from $applite_env - skipping panel DB restore"
        fi
    else
        log INFO "No panelalpha-panel.sql in snapshot - skipping"
    fi

    # Application volumes only — do not restore database-*-data (would override SQL)
    restore_volume "$ENGINE_DIR" "core-storage" "$data_dir/volumes/core-storage.tar.gz" || \
        log WARN "Volume core-storage restore failed"

    # Restore app-lite data/api-storage
    local applite_storage_src="$data_dir/config/panel/data/api-storage"
    if [[ -d "$applite_storage_src" ]]; then
        log INFO "Restoring app-lite data/api-storage..."
        mkdir -p "$PANEL_DIR/data/api-storage"
        if command -v rsync &>/dev/null; then
            rsync -a "${applite_storage_src}/" "$PANEL_DIR/data/api-storage/" 2>/dev/null || \
                cp -a "${applite_storage_src}/." "$PANEL_DIR/data/api-storage/" 2>/dev/null || \
                log WARN "api-storage restore incomplete"
        else
            cp -a "${applite_storage_src}/." "$PANEL_DIR/data/api-storage/" 2>/dev/null || \
                log WARN "api-storage restore incomplete"
        fi
    else
        log INFO "No app-lite data/api-storage in snapshot - skipping"
    fi

    # Restore users/ and /home
    _restore_users_and_home "$data_dir"

    # Start engine first, then panel
    log INFO "Starting engine services..."
    dc "$ENGINE_DIR" up -d
    sleep 15
    log INFO "Starting panel services..."
    dc "$PANEL_DIR" up -d
    sleep 10

    restore_root_crontab "$data_dir"
    dc "$ENGINE_DIR" ps 2>/dev/null || true
    dc "$PANEL_DIR"  ps 2>/dev/null || true
    log INFO "Single-server restore complete"
}

