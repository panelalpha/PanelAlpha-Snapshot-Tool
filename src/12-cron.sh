# ======================
# CRON AUTOMATION
# ======================

manage_cron() {
    local action="${1:-}"
    case "$action" in
        install) install_cron_job ;;
        remove)  remove_cron_job ;;
        status)  show_cron_status ;;
        *)
            log ERROR "Invalid cron action: $action"
            log ERROR "Valid actions: install, remove, status"
            exit 1
            ;;
    esac
}

install_cron_job() {
    log INFO "=== Installing Automatic Snapshot Schedule ==="
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
    local backup_hour="${BACKUP_HOUR:-2}"

    if ! [[ "$backup_hour" =~ ^[0-9]+$ ]] || [[ $backup_hour -lt 0 ]] || [[ $backup_hour -gt 23 ]]; then
        log WARN "Invalid BACKUP_HOUR in config: $backup_hour - using default 2"
        backup_hour=2
    fi

    local cron_line="0 $backup_hour * * * $SCRIPT_DIR/pasnap.sh --snapshot >> $LOG_FILE 2>&1"

    if crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/pasnap.sh"; then
        log WARN "Cron job already exists:"
        crontab -l 2>/dev/null | grep "$SCRIPT_DIR/pasnap.sh" || true
        echo ""
        read -r -p "Replace it? (yes/no): " replace
        if [[ "$replace" != "yes" ]]; then
            log INFO "Installation cancelled"
            return 0
        fi
        crontab -l 2>/dev/null | grep -v "$SCRIPT_DIR/pasnap.sh" | crontab - || true
    fi

    if (crontab -l 2>/dev/null; echo "$cron_line") | crontab -; then
        log INFO "Cron job installed: daily at ${backup_hour}:00"
        log INFO "Log: $LOG_FILE"
        log INFO "Entry: $cron_line"
    else
        log ERROR "Failed to install cron job"
        exit 1
    fi
}

remove_cron_job() {
    log INFO "=== Removing Automatic Snapshot Schedule ==="
    check_root

    if ! crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/pasnap.sh"; then
        log INFO "No cron job found"
        return 0
    fi

    if crontab -l 2>/dev/null | grep -v "$SCRIPT_DIR/pasnap.sh" | crontab -; then
        log INFO "Cron job removed"
    else
        log ERROR "Failed to remove cron job"
        exit 1
    fi
}

show_cron_status() {
    log INFO "=== Automatic Snapshot Status ==="

    if crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/pasnap.sh"; then
        echo "Automatic snapshots: ENABLED"
        echo ""
        echo "Schedule:"
        crontab -l 2>/dev/null | grep "$SCRIPT_DIR/pasnap.sh" || echo "  (could not retrieve)"
        echo ""
        echo "Log file: $LOG_FILE"
        if [[ -f "$LOG_FILE" ]]; then
            echo ""
            echo "Recent activity (last 10 lines):"
            echo "----------------------------------------"
            tail -10 "$LOG_FILE" 2>/dev/null || echo "  (no recent activity)"
        else
            echo ""
            echo "Log file not found - no recent activity"
        fi
    else
        echo "Automatic snapshots: DISABLED"
        echo ""
        echo "Enable with: $0 --cron install"
    fi
    echo ""
}

# ======================
# QUICKSTART
# ======================

quickstart() {
    log INFO "=== Quickstart ==="
    check_root

    if ! command -v restic &>/dev/null; then
        log INFO "restic not found - installing dependencies..."
        install_dependencies
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log INFO "No configuration found - starting setup..."
        setup_config
    fi

    create_snapshot
}

