# ======================
# VOLUME / PATH HELPERS
# ======================

# snapshot_docker_volume compose_dir volume_suffix out_tar_gz [required=true]
# Fail-closed: exits with 1 if required volume is missing or archive is too small.
snapshot_docker_volume() {
    local compose_dir="$1"
    local volume_suffix="$2"
    local out_tar_gz="$3"
    local required="${4:-true}"

    local project_name
    project_name=$(basename "$compose_dir")
    local full_volume_name="${project_name}_${volume_suffix}"
    local target_dir
    target_dir=$(dirname "$out_tar_gz")
    local target_file
    target_file=$(basename "$out_tar_gz")

    if ! docker volume inspect "$full_volume_name" &>/dev/null; then
        if [[ "$required" == "true" ]]; then
            log ERROR "Required volume not found: $full_volume_name"
            return 1
        else
            log INFO "Optional volume not found, skipping: $full_volume_name"
            return 0
        fi
    fi

    log INFO "Snapshotting volume: $volume_suffix"
    mkdir -p "$target_dir"

    docker run --rm \
        -v "${full_volume_name}:/source:ro" \
        -v "${target_dir}:/target" \
        ubuntu:20.04 \
        tar czf "/target/${target_file}" \
        --warning=no-file-changed \
        --ignore-failed-read \
        -C /source . 2>/dev/null || true

    if [[ ! -f "$out_tar_gz" ]] || [[ "$(stat -c%s "$out_tar_gz" 2>/dev/null || echo 0)" -lt 1000 ]]; then
        log ERROR "Volume snapshot failed or file too small: $out_tar_gz"
        rm -f "$out_tar_gz" 2>/dev/null || true
        return 1
    fi

    local sz
    sz=$(stat -c%s "$out_tar_gz" 2>/dev/null || echo "0")
    log INFO "Volume $volume_suffix snapshotted ($(( sz / 1024 )) KB)"
    return 0
}

# snapshot_path src_dir dest_dir [mode=false] — rsync with cp fallback.
# mode=false skips .git/, node_modules/, vendor/, cache/ and *.log.
# mode=true keeps vendor/, cache/ and *.log (panel code under packages/).
# mode=all copies everything (customer project files under users/).
snapshot_path() {
    local src="$1"
    local dest="$2"
    local mode="${3:-false}"

    mkdir -p "$dest"

    local excludes=()
    if [[ "$mode" != "all" ]]; then
        excludes+=(--exclude='.git/' --exclude='node_modules/')
    fi
    if [[ "$mode" == "false" ]]; then
        excludes+=(--exclude='vendor/' --exclude='cache/' --exclude='*.log')
    fi

    if command -v rsync &>/dev/null; then
        if rsync -a "${excludes[@]}" "${src}/" "${dest}/" 2>/dev/null; then
            return 0
        fi
    fi

    if cp -a "${src}/." "${dest}/" 2>/dev/null; then
        return 0
    fi

    return 1
}

# log_stderr_tail file — log the last lines a failed command wrote to stderr.
log_stderr_tail() {
    local err_file="$1"
    local line
    [[ -s "$err_file" ]] || return 0
    while IFS= read -r line; do
        log ERROR "  $line"
    done < <(tail -n 5 "$err_file")
}

# Panel version from the version file the installer writes; empty if missing.
# A release has one line ("1.9.8.6"). A git install has one commit per repo,
# so lines are joined with commas.
read_panel_version() {
    [[ -n "$PANEL_DIR" && -f "$PANEL_DIR/version" ]] || return 0
    tr -d '\r ' < "$PANEL_DIR/version" 2>/dev/null | grep -v '^$' | paste -sd, - || true
}

# Turn a path from the panel .env into an absolute path ("./crt/x" -> "$PANEL_DIR/crt/x").
resolve_panel_path() {
    local path="$1"
    [[ -z "$path" ]] && return 0
    [[ "$path" != /* ]] && path="$PANEL_DIR/${path#./}"
    echo "$path"
}

# Log admin 2FA row count and warn if APP_KEY is missing from snapshotted panel env.
# verify_panel_2fa_snapshot compose_dir service user password db_name snap_config_dir
verify_panel_2fa_snapshot() {
    local compose_dir="$1"
    local service="$2"
    local user="$3"
    local password="$4"
    local db_name="$5"
    local snap_config_dir="$6"

    local container
    container=$(dc_container_id "$compose_dir" "$service")
    if [[ -n "$container" ]]; then
        local count=""
        count=$(mariadb_exec "$container" "$user" "$password" "$db_name" -N \
            -e "SELECT COUNT(*) FROM admins WHERE two_factor_confirmed_at IS NOT NULL;" \
            2>/dev/null || true)
        if [[ -n "$count" && "$count" =~ ^[0-9]+$ ]]; then
            log INFO "$count admin(s) with 2FA enabled in database '$db_name'"
        else
            log WARN "Could not count admins with 2FA in database '$db_name'"
        fi
    fi

    local app_key=""
    if [[ -f "$snap_config_dir/.env-api" ]]; then
        app_key=$(get_env_var "APP_KEY" "$snap_config_dir/.env-api")
    fi
    if [[ -z "$app_key" && -f "$snap_config_dir/.env" ]]; then
        app_key=$(get_env_var "APP_KEY" "$snap_config_dir/.env")
    fi
    if [[ -z "$app_key" ]]; then
        log WARN "APP_KEY missing from snapshotted panel env — admin 2FA secrets will not decrypt after restore"
    else
        log INFO "APP_KEY present in snapshotted panel env (required for admin 2FA)"
    fi
}

# dump_mariadb_database compose_dir service user password db_name outfile
dump_mariadb_database() {
    local compose_dir="$1"
    local service="$2"
    local user="$3"
    local password="$4"
    local db_name="$5"
    local outfile="$6"

    local container
    container=$(dc_container_id "$compose_dir" "$service")
    if [[ -z "$container" ]]; then
        log ERROR "Container for service '$service' not found in $compose_dir"
        return 1
    fi

    log INFO "Dumping database '$db_name' from $service..."
    local err_file
    err_file=$(mktemp)
    if ! timeout "${CORE_DUMP_TIMEOUT}" docker exec -e MYSQL_PWD="$password" "$container" \
        mariadb-dump -u "$user" "$db_name" \
        --single-transaction --routines --triggers --lock-tables=false \
        --add-drop-database --create-options --disable-keys \
        --extended-insert --quick --set-charset \
        > "$outfile" 2>"$err_file"; then
        log ERROR "Failed to dump database '$db_name'"
        log_stderr_tail "$err_file"
        rm -f "$err_file"
        return 1
    fi
    rm -f "$err_file"

    if ! verify_file_integrity "$outfile" 1000; then
        log ERROR "Database dump appears corrupted: $outfile"
        return 1
    fi

    local sz
    sz=$(stat -c%s "$outfile" 2>/dev/null || echo "0")
    log INFO "Database '$db_name' dumped ($(( sz / 1024 )) KB)"
    return 0
}

# dump_mariadb_all compose_dir service user password outfile_base [use_gzip=false]
# Tries gzip first if use_gzip=true; falls back to uncompressed.
dump_mariadb_all() {
    local compose_dir="$1"
    local service="$2"
    local user="$3"
    local password="$4"
    local outfile_base="$5"
    local use_gzip="${6:-false}"

    local container
    container=$(dc_container_id "$compose_dir" "$service")
    if [[ -z "$container" ]]; then
        log ERROR "Container for service '$service' not found in $compose_dir"
        return 1
    fi

    local dump_args=(
        mariadb-dump -u "$user"
        --all-databases
        --single-transaction --routines --triggers --lock-tables=false
        --add-drop-database --create-options --disable-keys
        --extended-insert --quick --set-charset --tz-utc
        --hex-blob --max-allowed-packet=512M
    )

    log INFO "Dumping all databases from $service (may take a while)..."

    local final_outfile="$outfile_base"
    local dump_ok=false

    if [[ "$use_gzip" == "true" ]] && command -v gzip &>/dev/null; then
        if timeout "${USERS_DUMP_TIMEOUT}" docker exec -e MYSQL_PWD="$password" "$container" \
            sh -c "${dump_args[*]} 2>/dev/null | gzip -c -${USERS_DUMP_COMPRESSION_LEVEL}" \
            > "${outfile_base}.gz" 2>/dev/null; then
            final_outfile="${outfile_base}.gz"
            dump_ok=true
        else
            log WARN "Compressed dump failed, retrying uncompressed..."
            rm -f "${outfile_base}.gz" 2>/dev/null || true
        fi
    fi

    if [[ "$dump_ok" == "false" ]]; then
        if timeout "${USERS_DUMP_TIMEOUT}" docker exec -e MYSQL_PWD="$password" "$container" \
            "${dump_args[@]}" > "$outfile_base" 2>/dev/null; then
            final_outfile="$outfile_base"
            dump_ok=true
        fi
    fi

    if [[ "$dump_ok" == "false" ]]; then
        log ERROR "Failed to dump all databases from $service"
        return 1
    fi

    if ! verify_file_integrity "$final_outfile" 1000; then
        log ERROR "Dump appears corrupted: $final_outfile"
        return 1
    fi

    local sz
    sz=$(stat -c%s "$final_outfile" 2>/dev/null || echo "0")
    log INFO "All databases from $service dumped to $(basename "$final_outfile") ($(( sz / 1024 )) KB)"
    return 0
}

