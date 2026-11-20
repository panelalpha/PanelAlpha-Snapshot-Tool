# ======================
# CONFIGURATION LOADING
# ======================

load_configuration() {
    # Migrate from old config location
    if [[ -f "/opt/panelalpha/app/.env-backup" ]] && [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$(dirname "$CONFIG_FILE")"
        mv "/opt/panelalpha/app/.env-backup" "$CONFIG_FILE"
        log INFO "Migrated configuration from /opt/panelalpha/app/.env-backup to $CONFIG_FILE"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        # Remove stale PANELALPHA_DIR key if present
        if grep -q "^PANELALPHA_DIR=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '/^PANELALPHA_DIR=/d' "$CONFIG_FILE" 2>/dev/null || true
            sed -i '/^# PanelAlpha application settings$/d' "$CONFIG_FILE" 2>/dev/null || true
        fi
        set -a
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        set +a
        log DEBUG "Configuration loaded from $CONFIG_FILE"
    else
        log DEBUG "No configuration found at $CONFIG_FILE"
    fi

    BACKUP_TEMP_DIR="${BACKUP_TEMP_DIR:-/var/tmp}/pasnap-snapshot-$(date +%Y%m%d-%H%M%S)"
    RESTORE_TEMP_DIR="${RESTORE_TEMP_DIR:-/var/tmp}/pasnap-restore-$(date +%Y%m%d-%H%M%S)"
    LOG_FILE="${LOG_FILE:-/var/log/pasnap.log}"
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
    RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"
    BACKUP_TAG="panelalpha-${INSTALLATION_TYPE}-$(hostname)"
}

