# ======================
# SNAPSHOT CREATION (MAIN)
# ======================

create_snapshot() {
    log INFO "=== Creating PanelAlpha Snapshot ==="
    check_requirements
    log_installation_banner

    local random_suffix
    random_suffix=$(openssl rand -hex 4 2>/dev/null || date +%s)
    BACKUP_TEMP_DIR="${BACKUP_TEMP_DIR}-${random_suffix}"

    if ! mkdir -p "$BACKUP_TEMP_DIR"; then
        log ERROR "Cannot create temp directory: $BACKUP_TEMP_DIR"
        exit 1
    fi
    chmod 700 "$BACKUP_TEMP_DIR"
    trap 'cleanup_temp_dir' EXIT ERR

    log INFO "Temp directory: $BACKUP_TEMP_DIR"

    local start_time
    start_time=$(date +%s)

    case "$INSTALLATION_TYPE" in
        multi-server)
            snapshot_profile_multi_server  "$BACKUP_TEMP_DIR" || { log ERROR "Multi-server snapshot failed"; exit 1; }
            ;;
        engine)
            snapshot_profile_engine        "$BACKUP_TEMP_DIR" || { log ERROR "Engine snapshot failed"; exit 1; }
            ;;
        single-server)
            snapshot_profile_single_server "$BACKUP_TEMP_DIR" || { log ERROR "Single-server snapshot failed"; exit 1; }
            ;;
    esac

    local total_size
    total_size=$(du -sh "$BACKUP_TEMP_DIR" 2>/dev/null | cut -f1 || echo "unknown")
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    log INFO "Snapshot data: $total_size (${duration}s)"
    snapshot_root_crontab "$BACKUP_TEMP_DIR"
    create_snapshot_metadata "$BACKUP_TEMP_DIR" "$total_size" "$duration"

    # Initialize or verify restic repository
    local attempt=0
    local repo_ready=false
    while [[ $attempt -lt $MAX_RETRY_ATTEMPTS ]]; do
        if restic init --repo "$RESTIC_REPOSITORY" 2>/dev/null; then
            repo_ready=true
            break
        elif restic snapshots --repo "$RESTIC_REPOSITORY" --last 1 >/dev/null 2>&1; then
            repo_ready=true
            break
        fi
        attempt=$((attempt + 1))
        if [[ $attempt -lt $MAX_RETRY_ATTEMPTS ]]; then
            log WARN "Repository init retry ($attempt/$MAX_RETRY_ATTEMPTS)..."
            sleep 5
        fi
    done

    if [[ "$repo_ready" == "false" ]]; then
        log ERROR "Cannot initialize or access repository after $MAX_RETRY_ATTEMPTS attempts"
        exit 1
    fi

    log INFO "Uploading snapshot to repository..."
    local upload_start
    upload_start=$(date +%s)

    local restic_tags=(--tag "$BACKUP_TAG" --tag "databases" --tag "volumes" --tag "config")
    case "$INSTALLATION_TYPE" in
        engine|single-server)
            restic_tags+=(--tag "users" --tag "home")
            ;;
    esac

    local snapshot_result=""
    snapshot_result=$(restic backup "$BACKUP_TEMP_DIR" \
        --repo "$RESTIC_REPOSITORY" \
        "${restic_tags[@]}" \
        --verbose \
        --json 2>/dev/null) || {
        log ERROR "Failed to create snapshot in repository"
        log ERROR "Check network connection and repository settings"
        exit 1
    }

    local upload_end upload_duration snapshot_id
    upload_end=$(date +%s)
    upload_duration=$((upload_end - upload_start))
    snapshot_id=$(echo "$snapshot_result" | jq -r 'select(.snapshot_id != null) | .snapshot_id' \
        2>/dev/null | tail -1 || echo "")
    # Restic 0.16+ prints the full 64-character ID; --restore takes the 8-character short ID.
    snapshot_id="${snapshot_id:0:8}"

    # Light integrity check on uploaded data
    log INFO "Verifying repository integrity (sample)..."
    if ! restic check --repo "$RESTIC_REPOSITORY" --read-data-subset=1/10 2>/dev/null; then
        log WARN "Repository sample check reported issues - run: restic check --repo \"\$RESTIC_REPOSITORY\""
    else
        log INFO "Repository sample check passed"
    fi

    # Apply retention policy
    log INFO "Applying retention policy ($BACKUP_RETENTION_DAYS days)..."
    restic forget \
        --repo "$RESTIC_REPOSITORY" \
        --tag "$BACKUP_TAG" \
        --keep-daily "$BACKUP_RETENTION_DAYS" \
        --prune 2>/dev/null || log WARN "Retention policy failed"

    local snapshot_count
    snapshot_count=$(restic snapshots --repo "$RESTIC_REPOSITORY" \
        --tag "$BACKUP_TAG" --json 2>/dev/null | jq length 2>/dev/null || echo "0")

    log INFO "=== Snapshot completed successfully ==="
    log INFO "Snapshots in repository: $snapshot_count"

    if [[ -n "$snapshot_id" && "$snapshot_id" != "null" ]]; then
        echo ""
        echo "SUCCESS"
        echo "Snapshot ID: $snapshot_id"
        echo "Size:        $total_size"
        echo "Time:        ${duration}s (local) + ${upload_duration}s (upload)"
        echo ""
        echo "To restore: sudo $0 --restore $snapshot_id"
    fi
}

# ======================
# SNAPSHOT MANAGEMENT
# ======================

list_snapshots() {
    log INFO "=== Available Snapshots ==="
    check_requirements

    echo ""
    if ! restic snapshots --repo "$RESTIC_REPOSITORY" --compact --tag "$BACKUP_TAG" 2>/dev/null; then
        log WARN "No snapshots found with tag '$BACKUP_TAG'"
        log INFO "All snapshots in repository:"
        restic snapshots --repo "$RESTIC_REPOSITORY" --compact 2>/dev/null || {
            log ERROR "Failed to list snapshots"
            return 1
        }
    fi
    echo ""
}

delete_snapshot() {
    local snapshot_id_input="$1"
    [[ -z "$snapshot_id_input" ]] && { log ERROR "Snapshot ID required"; exit 1; }

    log INFO "=== Deleting Snapshot: $snapshot_id_input ==="
    check_requirements

    if ! restic snapshots --repo "$RESTIC_REPOSITORY" --json 2>/dev/null | \
        jq -r '.[].short_id' | grep -q "^${snapshot_id_input}$" 2>/dev/null; then
        log ERROR "Snapshot $snapshot_id_input not found"
        log INFO "Available snapshots:"
        restic snapshots --repo "$RESTIC_REPOSITORY" --compact 2>/dev/null || true
        exit 1
    fi

    echo ""
    log INFO "Snapshot to delete:"
    restic snapshots --repo "$RESTIC_REPOSITORY" "$snapshot_id_input" 2>/dev/null || true
    echo ""
    read -r -p "Delete snapshot $snapshot_id_input? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log INFO "Deletion cancelled"
        return 0
    fi

    if restic forget --repo "$RESTIC_REPOSITORY" "$snapshot_id_input" --prune; then
        log INFO "Snapshot $snapshot_id_input deleted"
    else
        log ERROR "Failed to delete snapshot $snapshot_id_input"
        exit 1
    fi
}

# ======================
# TEST AND VERIFY
# ======================

test_repository_connection() {
    log INFO "=== Testing Repository Connection ==="
    check_root

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log ERROR "Configuration not found: $CONFIG_FILE"
        log ERROR "Run: $0 --setup"
        exit 1
    fi

    set -a
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    set +a

    if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD:-}" ]]; then
        log ERROR "RESTIC_REPOSITORY and RESTIC_PASSWORD must be set"
        exit 1
    fi

    if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
        export AWS_ACCESS_KEY_ID
    fi
    if [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        export AWS_SECRET_ACCESS_KEY
    fi

    if ! command -v restic &>/dev/null; then
        log ERROR "Restic not installed. Run: $0 --install"
        exit 1
    fi

    mkdir -p "${RESTIC_CACHE_DIR:-/var/cache/restic}"
    export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"

    log INFO "Repository: $RESTIC_REPOSITORY"
    log INFO "Testing connection..."

    if restic -r "$RESTIC_REPOSITORY" snapshots &>/dev/null; then
        local count
        count=$(restic -r "$RESTIC_REPOSITORY" snapshots --json 2>/dev/null | jq length 2>/dev/null || echo "0")
        log INFO "Connection successful - $count snapshots found"
        return 0
    else
        log INFO "Repository not initialized, attempting init..."
        if restic -r "$RESTIC_REPOSITORY" init; then
            log INFO "Repository initialized successfully"
            return 0
        else
            log ERROR "Failed to connect or initialize repository"
            log ERROR "Check your configuration and credentials"
            return 1
        fi
    fi
}

verify_database_connections() {
    log INFO "=== Database Connection Verification ==="
    check_root
    require_installation
    log_installation_banner

    local all_ok=true

    case "$INSTALLATION_TYPE" in
        multi-server)
            _verify_db_multi_server || all_ok=false
            ;;
        engine)
            _verify_db_engine || all_ok=false
            ;;
        single-server)
            _verify_db_engine || all_ok=false
            _verify_db_single_server_panel || all_ok=false
            ;;
    esac

    if [[ "$all_ok" == "true" ]]; then
        log INFO "Database verification passed"
        return 0
    fi
    log ERROR "Database verification failed"
    return 1
}

_verify_db_multi_server() {
    local env_file="$PANEL_DIR/.env"
    local env_api="$PANEL_DIR/.env-api"

    local container
    container=$(dc_container_id "$PANEL_DIR" "database-api")
    if [[ -z "$container" ]]; then
        log ERROR "database-api container not running"
        return 1
    fi
    log INFO "database-api container running"

    local api_password=""
    if resolve_db_password "$container" "panelalpha" "API_MYSQL_PASSWORD" api_password "$env_file"; then
        log INFO "Connected to database-api (panelalpha user)"
    elif [[ -f "$env_api" ]] && \
         resolve_db_password "$container" "panelalpha" "API_MYSQL_PASSWORD" api_password "$env_api"; then
        log INFO "Connected to database-api using .env-api"
    else
        log ERROR "Cannot connect to database-api"
        return 1
    fi
    return 0
}

_verify_db_engine() {
    local env_file=""
    [[ -f "$ENGINE_DIR/.env" ]] && env_file="$ENGINE_DIR/.env" || env_file="$ENGINE_DIR/.env-core"

    local all_ok=true

    local core_container
    core_container=$(dc_container_id "$ENGINE_DIR" "database-core")
    if [[ -z "$core_container" ]]; then
        log ERROR "database-core container not running"
        all_ok=false
    else
        log INFO "database-core container running"
        local core_password=""
        if resolve_db_password "$core_container" "core" "CORE_MYSQL_PASSWORD" core_password "$env_file"; then
            log INFO "Connected to database-core (core user)"
        else
            log ERROR "Cannot connect to database-core"
            all_ok=false
        fi
    fi

    local users_container
    users_container=$(dc_container_id "$ENGINE_DIR" "database-users")
    if [[ -z "$users_container" ]]; then
        log ERROR "database-users container not running"
        all_ok=false
    else
        log INFO "database-users container running"
        local users_password=""
        if resolve_db_password "$users_container" "root" "USERS_MYSQL_ROOT_PASSWORD" users_password "$env_file"; then
            log INFO "Connected to database-users (root user)"
        else
            log ERROR "Cannot connect to database-users"
            all_ok=false
        fi
    fi

    [[ "$all_ok" == "true" ]]
}

_verify_db_single_server_panel() {
    local applite_env="$PANEL_DIR/.env"
    if [[ ! -f "$applite_env" ]]; then
        log ERROR "App-lite .env not found: $applite_env"
        return 1
    fi

    local panel_db panel_user panel_password
    panel_db=$(get_env_var "DB_DATABASE" "$applite_env")
    panel_user=$(get_env_var "DB_USERNAME" "$applite_env")
    panel_password=$(get_env_var "DB_PASSWORD" "$applite_env")

    local core_container
    core_container=$(dc_container_id "$ENGINE_DIR" "database-core")
    if [[ -z "$core_container" ]]; then
        log ERROR "database-core not running (needed for panel DB verification)"
        return 1
    fi

    if test_mariadb_connection "$core_container" "$panel_user" "$panel_password"; then
        log INFO "Panel DB connection verified (db: $panel_db, user: $panel_user via database-core)"
        return 0
    else
        log ERROR "Cannot connect to panel DB ($panel_db) as $panel_user via database-core"
        return 1
    fi
}

