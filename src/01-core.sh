# ======================
# CONSTANTS
# ======================

readonly SCRIPT_VERSION="1.4.0"
readonly SCRIPT_NAME="PanelAlpha Snapshot & Restore Tool"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

readonly CONFIG_DIR="/opt/panelalpha/pasnap"
readonly CONFIG_FILE="${CONFIG_DIR}/.env-backup"

readonly MARIADB_TIMEOUT=30
readonly MAX_RETRY_ATTEMPTS=3
readonly CORE_DUMP_TIMEOUT="${PASNAP_CORE_DUMP_TIMEOUT:-600}"
readonly USERS_DUMP_TIMEOUT="${PASNAP_USERS_DUMP_TIMEOUT:-1800}"
readonly USERS_DUMP_COMPRESSION_LEVEL="${PASNAP_USERS_DUMP_COMPRESSION_LEVEL:-1}"
readonly VOLUME_SNAPSHOT_TIMEOUT="${PASNAP_VOLUME_SNAPSHOT_TIMEOUT:-7200}"
readonly USERS_HOME_SNAPSHOT_TIMEOUT="${PASNAP_USERS_HOME_SNAPSHOT_TIMEOUT:-14400}"

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m'

# ======================
# GLOBAL STATE (set by detect_installation)
# ======================

INSTALLATION_TYPE="unknown"
PANEL_DIR=""    # /opt/panelalpha/app (multi-server) | /opt/panelalpha/app-lite (single-server) | "" (engine)
ENGINE_DIR=""   # /opt/panelalpha/shared-hosting | "" (multi-server)
SNAPSHOT_ID=""  # set by resolve_snapshot()

# ======================
# INSTALLATION DETECTION
# ======================

detect_installation() {
    local applite_compose="/opt/panelalpha/app-lite/docker-compose.yml"
    local shared_compose="/opt/panelalpha/shared-hosting/docker-compose.yml"
    local app_compose="/opt/panelalpha/app/docker-compose.yml"

    local has_applite=false
    local has_shared_hosting=false

    [[ -f "$applite_compose" ]] && has_applite=true
    [[ -f "$shared_compose" ]] && has_shared_hosting=true

    if [[ "$has_applite" == "true" && "$has_shared_hosting" == "true" ]]; then
        INSTALLATION_TYPE="single-server"
        PANEL_DIR="/opt/panelalpha/app-lite"
        ENGINE_DIR="/opt/panelalpha/shared-hosting"
    elif [[ "$has_shared_hosting" == "true" ]]; then
        INSTALLATION_TYPE="engine"
        PANEL_DIR=""
        ENGINE_DIR="/opt/panelalpha/shared-hosting"
    elif [[ -f "$app_compose" ]]; then
        INSTALLATION_TYPE="multi-server"
        PANEL_DIR="/opt/panelalpha/app"
        ENGINE_DIR=""
    else
        INSTALLATION_TYPE="unknown"
        PANEL_DIR=""
        ENGINE_DIR=""
    fi
}

require_installation() {
    if [[ "$INSTALLATION_TYPE" == "unknown" ]]; then
        log ERROR "PanelAlpha installation not detected. Expected one of:"
        log ERROR "  /opt/panelalpha/app/docker-compose.yml                                           (multi-server)"
        log ERROR "  /opt/panelalpha/app-lite/docker-compose.yml + /opt/panelalpha/shared-hosting/... (single-server)"
        log ERROR "  /opt/panelalpha/shared-hosting/docker-compose.yml                                (engine)"
        exit 1
    fi
}

log_installation_banner() {
    log INFO "----------------------------------------"
    log INFO "Installation Type: $INSTALLATION_TYPE"
    [[ -n "$PANEL_DIR" ]]  && log INFO "Panel Dir:         $PANEL_DIR"
    [[ -n "$ENGINE_DIR" ]] && log INFO "Engine Dir:        $ENGINE_DIR"
    log INFO "----------------------------------------"
}

