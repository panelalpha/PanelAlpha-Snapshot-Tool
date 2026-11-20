# ======================
# VERSION CHECK / UPDATE
# ======================

# Return 0 if $1 is a newer semver than $2 (MAJOR.MINOR.PATCH only).
is_version_newer() {
    local newer_candidate="$1"
    local current="$2"
    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<< "${newer_candidate%%[!0-9.]*}"
    IFS=. read -r b1 b2 b3 <<< "${current%%[!0-9.]*}"
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
    if (( a1 > b1 )); then return 0; fi
    if (( a1 < b1 )); then return 1; fi
    if (( a2 > b2 )); then return 0; fi
    if (( a2 < b2 )); then return 1; fi
    if (( a3 > b3 )); then return 0; fi
    return 1
}

download_and_apply_update() {
    local temp_file="$1"
    local backup_file="$2"
    local remote_version="$3"
    shift 3

    if [[ -s "$temp_file" ]] && grep -q "SCRIPT_VERSION" "$temp_file"; then
        if mv "$temp_file" "${SCRIPT_DIR}/pasnap.sh"; then
            chmod +x "${SCRIPT_DIR}/pasnap.sh"
            echo ""
            log INFO "Updated to version $remote_version (backup: $backup_file)"
            log INFO "Restarting with new version..."
            sleep 2
            exec "${SCRIPT_DIR}/pasnap.sh" "$@"
        else
            log ERROR "Failed to replace script (permission denied?)"
            rm -f "$temp_file"
            return 1
        fi
    else
        log ERROR "Downloaded file appears corrupted"
        rm -f "$temp_file"
        return 1
    fi
}

check_for_updates() {
    [[ "${PASNAP_SKIP_UPDATE_CHECK:-0}" == "1" ]] && return 0

    local auto_update="${PASNAP_AUTO_UPDATE:-}"
    local disable_auto_update="${PASNAP_DISABLE_AUTO_UPDATE:-0}"
    local force_check="${PASNAP_FORCE_UPDATE_CHECK:-0}"
    local is_interactive=true

    if [[ ! -t 0 ]]; then
        is_interactive=false
        if [[ -z "$auto_update" && "$disable_auto_update" != "1" ]]; then
            auto_update="1"
        fi
        if [[ "$auto_update" != "1" ]]; then
            log DEBUG "Non-interactive: skipping update check (set PASNAP_AUTO_UPDATE=1 to enable)"
            return 0
        fi
    fi

    local update_check_file="/var/tmp/.pasnap_last_update_check"
    local current_time
    current_time=$(date +%s)

    if [[ "$force_check" != "1" && -f "$update_check_file" ]]; then
        local last_check
        last_check=$(cat "$update_check_file" 2>/dev/null || echo "0")
        local time_diff=$((current_time - last_check))
        if [[ $time_diff -lt 86400 ]]; then
            return 0
        fi
    fi

    local remote_version=""
    local github_raw_url="https://raw.githubusercontent.com/panelalpha/PanelAlpha-Snapshot-Tool/main/pasnap.sh"

    if command -v curl &>/dev/null; then
        remote_version=$(timeout 5 curl -s "$github_raw_url" 2>/dev/null | \
            grep '^readonly SCRIPT_VERSION=' | cut -d'"' -f2 | head -1 || true)
    elif command -v wget &>/dev/null; then
        remote_version=$(timeout 5 wget -qO- "$github_raw_url" 2>/dev/null | \
            grep '^readonly SCRIPT_VERSION=' | cut -d'"' -f2 | head -1 || true)
    fi

    echo "$current_time" > "$update_check_file" 2>/dev/null || true

    [[ -z "$remote_version" ]] && return 0
    [[ "$remote_version" == "$SCRIPT_VERSION" ]] && { log DEBUG "Up to date (v$SCRIPT_VERSION)"; return 0; }

    # Never downgrade (e.g. local 1.3.0 vs published 1.2.4)
    if ! is_version_newer "$remote_version" "$SCRIPT_VERSION"; then
        log DEBUG "Local version $SCRIPT_VERSION is newer than or equal to remote $remote_version - skipping update"
        return 0
    fi

    echo ""
    echo "  Update available: $SCRIPT_VERSION -> $remote_version"
    echo ""

    local should_update=false
    if [[ "$auto_update" == "1" ]]; then
        log INFO "Auto-update enabled, updating to $remote_version..."
        should_update=true
    elif [[ "$is_interactive" == "true" ]]; then
        read -r -p "  Update now? (y/n): " -n 1
        echo ""
        [[ "$REPLY" =~ ^[Yy]$ ]] && should_update=true
    fi

    if [[ "$should_update" == "true" ]]; then
        local backup_file="${SCRIPT_DIR}/pasnap.sh.backup-$(date +%Y%m%d-%H%M%S)"
        cp "${SCRIPT_DIR}/pasnap.sh" "$backup_file" 2>/dev/null && \
            log INFO "Backup created: $backup_file" || \
            log WARN "Could not create backup"

        local temp_file download_ok=false
        temp_file=$(mktemp)
        if command -v curl &>/dev/null; then
            curl -sL "$github_raw_url" -o "$temp_file" 2>/dev/null && download_ok=true || true
        elif command -v wget &>/dev/null; then
            wget -q "$github_raw_url" -O "$temp_file" 2>/dev/null && download_ok=true || true
        fi

        if [[ "$download_ok" == "true" ]]; then
            download_and_apply_update "$temp_file" "$backup_file" "$remote_version" "$@"
        else
            log ERROR "Download failed"
            rm -f "$temp_file"
        fi
    else
        echo ""
        log INFO "Update skipped. To update manually:"
        echo "  wget -O ${SCRIPT_DIR}/pasnap.sh $github_raw_url"
        echo "  chmod +x ${SCRIPT_DIR}/pasnap.sh"
        echo ""
        log INFO "To enable auto-update: export PASNAP_AUTO_UPDATE=1"
        sleep 2
    fi
    return 0
}

# ======================
# HELP AND VERSION
# ======================

show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION

USAGE: $0 [option]

INSTALLATION AND CONFIGURATION:
  --install             Install required tools (restic, jq, rsync)
  --setup               Interactive repository configuration
  --quickstart          Install tools + configure + create first snapshot

SNAPSHOT OPERATIONS:
  --snapshot            Create new snapshot
  --snapshot-bg         Create snapshot in background (survives terminal close)
  --test-connection     Test repository connection
  --verify-database     Verify database credentials and connectivity

RESTORE OPERATIONS:
  --restore <snapshot>  Restore from snapshot (use 'latest' for newest)
  --list-snapshots      Show available snapshots
  --delete-snapshots <id>  Delete a snapshot by ID

AUTOMATION:
  --cron install        Install daily automatic snapshot cron job
  --cron remove         Remove automatic snapshot cron job
  --cron status         Show cron job status and recent activity

OTHER:
  --update              Force update to latest version
  --version             Show version and detected installation info
  --help, -h            Show this help

EXAMPLES:
  $0 --quickstart
  $0 --snapshot
  $0 --restore latest
  $0 --restore a1b2c3d4
  $0 --list-snapshots
  $0 --cron install

Configuration: $CONFIG_FILE
Logs:          /var/log/pasnap.log
EOF
}

show_version() {
    local restic_ver="" docker_ver=""

    echo "$SCRIPT_NAME v$SCRIPT_VERSION"
    echo ""
    echo "Detected installation:"
    echo "  Type: $INSTALLATION_TYPE"
    [[ -n "$PANEL_DIR" ]]  && echo "  Panel:  $PANEL_DIR"
    [[ -n "$ENGINE_DIR" ]] && echo "  Engine: $ENGINE_DIR"
    echo ""
    echo "Components:"
    if command -v restic &>/dev/null; then
        restic_ver=$(restic version 2>/dev/null | head -1 || true)
        echo "  restic: ${restic_ver:-installed}"
    else
        echo "  restic: not installed"
    fi
    if command -v docker &>/dev/null; then
        docker_ver=$(docker --version 2>/dev/null | head -1 || true)
        if [[ -n "$docker_ver" ]]; then
            echo "  docker: $docker_ver"
        else
            echo "  docker: present but not usable"
        fi
    else
        echo "  docker: not installed"
    fi
    echo ""
    echo "System:"
    echo "  OS:   $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown Linux')"
    echo "  Arch: $(uname -m)"
    echo ""
    echo "Copyright (c) $(date +%Y) - Apache-2.0 license"
}

