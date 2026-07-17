#!/bin/bash
# PanelAlpha Snapshot & Restore Tool
# Automated backup and disaster recovery for PanelAlpha Control Panel and Engine
# Usage: ./pasnap.sh [options]

set -euo pipefail

# ======================
# CONSTANTS
# ======================

readonly SCRIPT_VERSION="1.3.0"
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

# ======================
# LOGGING
# ======================

log_file_matches_fd() {
    local log_path="$1"
    local fd="$2"
    local log_stat fd_stat
    log_stat=$(stat -Lc '%d:%i' "$log_path" 2>/dev/null || true)
    fd_stat=$(stat -Lc '%d:%i' "/proc/$$/fd/$fd" 2>/dev/null || true)
    [[ -n "$log_stat" && "$log_stat" == "$fd_stat" ]]
}

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        INFO)  echo -e "${COLOR_GREEN}[$timestamp] INFO:${COLOR_NC} $message" ;;
        WARN)  echo -e "${COLOR_YELLOW}[$timestamp] WARN:${COLOR_NC} $message" >&2 ;;
        ERROR) echo -e "${COLOR_RED}[$timestamp] ERROR:${COLOR_NC} $message" >&2 ;;
        DEBUG) echo -e "${COLOR_BLUE}[$timestamp] DEBUG:${COLOR_NC} $message" ;;
        *)     echo -e "[$timestamp] $level: $message" ;;
    esac

    if [[ -n "${LOG_FILE:-}" ]]; then
        local log_dir
        log_dir="$(dirname "$LOG_FILE")"
        if { [[ -w "$log_dir" ]] || [[ -w "$LOG_FILE" ]]; } 2>/dev/null; then
            if ! log_file_matches_fd "$LOG_FILE" 1 2>/dev/null && \
               ! log_file_matches_fd "$LOG_FILE" 2 2>/dev/null; then
                echo "[$timestamp] $level: $message" >> "$LOG_FILE" 2>/dev/null || true
            fi
        fi
    fi
}

# ======================
# INPUT VALIDATION
# ======================

validate_input() {
    local input="$1"
    local type="$2"

    case "$type" in
        snapshot_id)
            if [[ ! "$input" =~ ^[a-zA-Z0-9]{8}$|^latest$ ]]; then
                log ERROR "Invalid snapshot ID format: $input"
                return 1
            fi
            ;;
        path)
            if [[ "$input" =~ \.\.|^/dev/|^/sys/|^/proc/ ]]; then
                log ERROR "Invalid path: $input"
                return 1
            fi
            ;;
        hour)
            if ! [[ "$input" =~ ^[0-9]+$ ]] || [[ $input -lt 0 ]] || [[ $input -gt 23 ]]; then
                log ERROR "Invalid hour: $input (must be 0-23)"
                return 1
            fi
            ;;
        retention_days)
            if ! [[ "$input" =~ ^[0-9]+$ ]] || [[ $input -lt 1 ]] || [[ $input -gt 365 ]]; then
                log ERROR "Invalid retention days: $input (must be 1-365)"
                return 1
            fi
            ;;
    esac
    return 0
}

verify_file_integrity() {
    local file_path="$1"
    local min_size="${2:-100}"

    if [[ ! -f "$file_path" ]] || [[ ! -r "$file_path" ]]; then
        log ERROR "File missing or unreadable: $file_path"
        return 1
    fi
    local file_size
    file_size=$(stat -c%s "$file_path" 2>/dev/null || echo "0")
    if [[ $file_size -lt $min_size ]]; then
        log ERROR "File too small ($file_size bytes): $file_path"
        return 1
    fi
    return 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log ERROR "This script must be run as root (use sudo)"
        exit 1
    fi
}

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

# snapshot_path src_dir dest_dir — rsync with cp fallback.
snapshot_path() {
    local src="$1"
    local dest="$2"

    mkdir -p "$dest"

    if command -v rsync &>/dev/null; then
        if rsync -a \
            --exclude='.git/' \
            --exclude='node_modules/' \
            --exclude='vendor/' \
            --exclude='cache/' \
            --exclude='*.log' \
            "${src}/" "${dest}/" 2>/dev/null; then
            return 0
        fi
    fi

    if cp -a "${src}/." "${dest}/" 2>/dev/null; then
        return 0
    fi

    return 1
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
    if ! timeout "${CORE_DUMP_TIMEOUT}" docker exec -e MYSQL_PWD="$password" "$container" \
        mariadb-dump -u "$user" "$db_name" \
        --single-transaction --routines --triggers --lock-tables=false \
        --add-drop-database --create-options --disable-keys \
        --extended-insert --quick --set-charset \
        > "$outfile" 2>/dev/null; then
        log ERROR "Failed to dump database '$db_name'"
        return 1
    fi

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

# ======================
# DEPENDENCY MANAGEMENT
# ======================

install_dependencies() {
    log INFO "=== Installing Dependencies ==="
    check_root

    log INFO "System: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown Linux')"
    log INFO "Architecture: $(uname -m)"

    log INFO "Updating package list..."
    if ! apt update >/dev/null 2>&1; then
        log ERROR "Failed to update package list"
        log ERROR "Check your internet connection and repository configuration"
        exit 1
    fi

    local packages_to_install=()

    if ! command -v restic &>/dev/null; then
        packages_to_install+=("restic")
    else
        log INFO "restic already installed: $(restic version 2>/dev/null | head -1 || echo unknown)"
    fi
    if ! command -v jq &>/dev/null; then
        packages_to_install+=("jq")
    else
        log INFO "jq already installed: $(jq --version 2>/dev/null || echo unknown)"
    fi
    if ! command -v rsync &>/dev/null; then
        packages_to_install+=("rsync")
    else
        log INFO "rsync already installed"
    fi

    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        log INFO "Installing: ${packages_to_install[*]}"
        local attempt=0
        local installed=false
        while [[ $attempt -lt $MAX_RETRY_ATTEMPTS ]]; do
            if apt install -y "${packages_to_install[@]}" >/dev/null 2>&1; then
                log INFO "Packages installed successfully"
                installed=true
                break
            fi
            attempt=$((attempt + 1))
            if [[ $attempt -lt $MAX_RETRY_ATTEMPTS ]]; then
                log WARN "Installation failed, retrying ($attempt/$MAX_RETRY_ATTEMPTS)..."
                sleep 5
            fi
        done
        if [[ "$installed" == "false" ]]; then
            log ERROR "Failed to install packages after $MAX_RETRY_ATTEMPTS attempts"
            exit 1
        fi
    else
        log INFO "All required packages already installed"
    fi

    if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
        log ERROR "Docker is not installed or not running"
        log ERROR "Install Docker: https://docs.docker.com/engine/install/"
        exit 1
    fi
    log INFO "Docker available: $(docker --version 2>/dev/null || echo unknown)"

    if ! docker compose version &>/dev/null && ! command -v docker-compose &>/dev/null; then
        log ERROR "Docker Compose not available"
        log ERROR "Install Docker Compose: https://docs.docker.com/compose/install/"
        exit 1
    fi
    log INFO "=== Dependencies installation completed ==="
    log INFO "Next step: $0 --setup"
}

# ======================
# SYSTEM VALIDATION
# ======================

check_requirements() {
    check_root
    require_installation

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log ERROR "Configuration not found: $CONFIG_FILE"
        log ERROR "Run: $0 --setup"
        exit 1
    fi

    if ! command -v restic &>/dev/null; then
        log ERROR "Restic not installed. Run: $0 --install"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        log ERROR "Docker daemon is not running"
        log ERROR "Start with: systemctl start docker"
        exit 1
    fi

    validate_repository_config
    check_system_resources
    mkdir -p "$RESTIC_CACHE_DIR"
    export RESTIC_CACHE_DIR
}

validate_repository_config() {
    if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD:-}" ]]; then
        log ERROR "RESTIC_REPOSITORY and RESTIC_PASSWORD must be configured"
        log ERROR "Run: $0 --setup"
        exit 1
    fi
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
        export AWS_ACCESS_KEY_ID
    fi
    if [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        export AWS_SECRET_ACCESS_KEY
    fi
    return 0
}

check_system_resources() {
    local temp_dir_parent
    temp_dir_parent="$(dirname "$BACKUP_TEMP_DIR")"
    local available_mb=""
    available_mb=$(df "$temp_dir_parent" 2>/dev/null | awk 'NR==2 {print int($4/1024)}' || true)
    if [[ -z "$available_mb" || ! "$available_mb" =~ ^[0-9]+$ ]]; then
        log WARN "Could not determine available disk space"
        return 0
    fi
    local required_mb=3000
    if [[ $available_mb -lt $required_mb ]]; then
        log ERROR "Insufficient disk space: ${available_mb}MB available, ${required_mb}MB required in $temp_dir_parent"
        exit 1
    fi
    log INFO "Disk space OK: ${available_mb}MB available"
}

test_repository_connectivity() {
    if ! restic -r "$RESTIC_REPOSITORY" snapshots &>/dev/null; then
        log INFO "Repository not found, initializing..."
        if ! restic -r "$RESTIC_REPOSITORY" init; then
            log ERROR "Failed to initialize repository"
            log ERROR "Check repository URL and credentials"
            exit 1
        fi
        log INFO "Repository initialized successfully"
    else
        log INFO "Repository connection OK"
    fi
}

# ======================
# SETUP CONFIGURATION
# ======================

setup_config() {
    log INFO "=== Snapshot Repository Configuration ==="
    check_root

    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Configuration already exists: $CONFIG_FILE"
        read -r -p "Overwrite? (yes/no): " overwrite
        if [[ "$overwrite" != "yes" ]]; then
            log INFO "Configuration unchanged"
            return 0
        fi
    fi

    echo ""
    echo "Repository types:"
    echo "  local - local storage on this server (suggested path: /backup/panelalpha)"
    echo "  sftp  - remote server via SFTP/SSH"
    echo "  s3    - cloud storage (AWS S3, Hetzner, MinIO, DigitalOcean Spaces)"
    echo ""

    local repo_type
    while true; do
        read -r -p "Repository type (local/sftp/s3): " repo_type
        [[ "$repo_type" =~ ^(local|sftp|s3)$ ]] && break
        echo "Choose: local, sftp, or s3"
    done

    local RESTIC_REPO="" AWS_ACCESS_KEY="" AWS_SECRET_KEY=""

    case "$repo_type" in
        local)
            echo ""
            echo "WARNING: Local backups are lost if this server fails."
            echo ""
            local backup_path
            while true; do
                read -r -p "Snapshot directory [/backup/panelalpha]: " backup_path
                backup_path="${backup_path:-/backup/panelalpha}"
                validate_input "$backup_path" "path" && break
            done
            mkdir -p "$backup_path" && chmod 700 "$backup_path"
            log INFO "Directory created with secure permissions"
            RESTIC_REPO="$backup_path"
            ;;
        sftp)
            echo ""
            echo "=== SFTP STORAGE ==="
            echo "NOTE: Ensure passwordless SSH access for root to the remote server."
            echo ""
            local sftp_user sftp_host sftp_path
            while true; do
                read -r -p "SFTP username: " sftp_user
                [[ -n "$sftp_user" ]] && break
                echo "Username cannot be empty"
            done
            while true; do
                read -r -p "SFTP server address: " sftp_host
                [[ -n "$sftp_host" ]] && break
                echo "Server address cannot be empty"
            done
            while true; do
                read -r -p "Remote path (e.g. /backup/panelalpha): " sftp_path
                [[ -n "$sftp_path" ]] && break
                echo "Path cannot be empty"
            done
            RESTIC_REPO="sftp:${sftp_user}@${sftp_host}:${sftp_path}"
            ;;
        s3)
            echo ""
            echo "=== S3 STORAGE ==="
            echo "Compatible with AWS S3, Hetzner, MinIO, DigitalOcean Spaces"
            echo ""
            local s3_access_key s3_secret_key s3_region s3_bucket s3_endpoint s3_prefix
            while true; do
                read -r -p "Access Key ID: " s3_access_key
                [[ -n "$s3_access_key" ]] && break
                echo "Access Key ID cannot be empty"
            done
            while true; do
                read -r -s -p "Secret Access Key: " s3_secret_key; echo
                [[ -n "$s3_secret_key" ]] && break
                echo "Secret Access Key cannot be empty"
            done
            while true; do
                read -r -p "Region (e.g. eu-west-1): " s3_region
                [[ -n "$s3_region" ]] && break
                echo "Region cannot be empty"
            done
            while true; do
                read -r -p "Bucket name: " s3_bucket
                [[ -n "$s3_bucket" ]] && break
                echo "Bucket name cannot be empty"
            done
            read -r -p "S3 Endpoint (leave empty for AWS, e.g. s3.hetzner.cloud): " s3_endpoint || true
            read -r -p "Path prefix in bucket [pasnap]: " s3_prefix || true
            s3_prefix="${s3_prefix:-pasnap}"

            if [[ -n "$s3_endpoint" ]]; then
                s3_endpoint="${s3_endpoint#https://}"
                s3_endpoint="${s3_endpoint#http://}"
                RESTIC_REPO="s3:${s3_endpoint}/${s3_bucket}/${s3_prefix}"
            else
                RESTIC_REPO="s3:s3.${s3_region}.amazonaws.com/${s3_bucket}/${s3_prefix}"
            fi
            AWS_ACCESS_KEY="$s3_access_key"
            AWS_SECRET_KEY="$s3_secret_key"
            ;;
    esac

    echo ""
    echo "IMPORTANT: You CANNOT restore backups without the encryption password."
    echo "           Store it securely (password manager, printed copy, secure vault)."
    echo ""
    local restic_password
    while true; do
        read -r -s -p "Repository encryption password (min 8 characters): " restic_password; echo
        if [[ ${#restic_password} -lt 8 ]]; then
            echo "Password must be at least 8 characters"
            continue
        fi
        local confirm_pw
        read -r -s -p "Confirm password: " confirm_pw; echo
        if [[ "$restic_password" == "$confirm_pw" ]]; then
            break
        fi
        echo "Passwords do not match. Try again."
    done

    local retention_days
    while true; do
        read -r -p "Retention period in days [30]: " retention_days
        retention_days="${retention_days:-30}"
        validate_input "$retention_days" "retention_days" && break
    done

    local backup_hour
    while true; do
        read -r -p "Automatic snapshot hour 0-23 [2]: " backup_hour
        backup_hour="${backup_hour:-2}"
        validate_input "$backup_hour" "hour" && break
    done

    mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR"

    cat > "$CONFIG_FILE" << EOF
# PanelAlpha Snapshot Configuration
# Generated: $(date)
# Version: $SCRIPT_VERSION

# Repository settings
RESTIC_REPOSITORY="$RESTIC_REPO"
RESTIC_PASSWORD="$restic_password"

# S3 credentials (empty for local/sftp)
AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY"
AWS_SECRET_ACCESS_KEY="$AWS_SECRET_KEY"

# Snapshot settings
BACKUP_RETENTION_DAYS=$retention_days
BACKUP_HOUR=$backup_hour
BACKUP_TAG_PREFIX="panelalpha"

# System paths and logging
LOG_FILE="/var/log/pasnap.log"
BACKUP_TEMP_DIR="/var/tmp"
RESTIC_CACHE_DIR="/var/cache/restic"
EOF

    chmod 600 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"
    log INFO "Configuration saved securely: $CONFIG_FILE"

    # Reload configuration with the new settings
    load_configuration

    log INFO "Testing repository connection..."
    if ! test_repository_connection; then
        log WARN "Repository connection test failed - check your settings"
        return 1
    fi

    log INFO "Verifying database connections..."
    if verify_database_connections; then
        log INFO "Database verification passed"
    else
        log WARN "Database verification reported issues - run: $0 --verify-database"
    fi

    log INFO "Setup complete."
    echo ""
    echo "Next steps:"
    echo "  1. Create first snapshot:    $0 --snapshot"
    echo "  2. Schedule automatic:       $0 --cron install"
    echo "  Or one-shot on a fresh host: $0 --quickstart"
}

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
- Volumes: api-storage, database-api-data, redis-data (${PANEL_DIR} project)
- Config: .env, .env-api, docker-compose.yml, packages/, SSL"
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

    # Config files
    for f in ".env" ".env-api" "docker-compose.yml"; do
        [[ -f "$PANEL_DIR/$f" ]] && cp "$PANEL_DIR/$f" "$snap_dir/config/panel/" 2>/dev/null || true
    done

    verify_panel_2fa_snapshot "$PANEL_DIR" "database-api" "panelalpha" "$api_password" \
        "panelalpha" "$snap_dir/config/panel"

    # packages/ directory
    if [[ -d "$PANEL_DIR/packages" ]]; then
        log INFO "Snapshotting packages directory..."
        if ! snapshot_path "$PANEL_DIR/packages" "$snap_dir/config/panel/packages"; then
            log WARN "packages snapshot may be incomplete"
        fi
    else
        log INFO "No packages directory found - skipping"
    fi

    # SSL certificates
    if [[ -d "/etc/letsencrypt" ]]; then
        log INFO "Snapshotting SSL certificates..."
        mkdir -p "$snap_dir/config/ssl"
        cp -r /etc/letsencrypt/ "$snap_dir/config/ssl/" 2>/dev/null || \
            log WARN "SSL certificate snapshot incomplete"
    fi

    log INFO "Multi-server profile snapshot complete"
    return 0
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
            if ! snapshot_path "$ENGINE_DIR/users" "$snap_dir/users"; then
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

# ======================
# RESTORE HELPERS
# ======================

resolve_snapshot() {
    local input="$1"

    if [[ "$input" == "latest" ]]; then
        SNAPSHOT_ID=$(restic snapshots --repo "$RESTIC_REPOSITORY" --tag "$BACKUP_TAG" \
            --json 2>/dev/null | jq -r 'if length > 0 then .[0].short_id else empty end' \
            2>/dev/null || echo "")

        if [[ -z "$SNAPSHOT_ID" || "$SNAPSHOT_ID" == "null" ]]; then
            SNAPSHOT_ID=$(restic snapshots --repo "$RESTIC_REPOSITORY" --tag "panelalpha" \
                --json 2>/dev/null | jq -r 'if length > 0 then .[0].short_id else empty end' \
                2>/dev/null || echo "")
        fi

        if [[ -z "$SNAPSHOT_ID" || "$SNAPSHOT_ID" == "null" ]]; then
            SNAPSHOT_ID=$(restic snapshots --repo "$RESTIC_REPOSITORY" \
                --json 2>/dev/null | jq -r 'if length > 0 then .[0].short_id else empty end' \
                2>/dev/null || echo "")
        fi

        if [[ -z "$SNAPSHOT_ID" || "$SNAPSHOT_ID" == "null" ]]; then
            log ERROR "No snapshots found in repository"
            log ERROR "Create a snapshot first: $0 --snapshot"
            exit 1
        fi
        log INFO "Latest snapshot: $SNAPSHOT_ID"
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
            if [[ -z "$cid" ]] || ! docker exec "$cid" mariadb-admin ping --silent 2>/dev/null; then
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
    local import_ok=false
    if [[ "$sql_file" == *.gz ]]; then
        if gunzip -c "$sql_file" | \
            mariadb_exec_stdin "$container" "$db_user" "$db_password" "$db_name" 2>/dev/null; then
            import_ok=true
        fi
    else
        if mariadb_exec_stdin "$container" "$db_user" "$db_password" "$db_name" \
            < "$sql_file" 2>/dev/null; then
            import_ok=true
        fi
    fi

    if [[ "$import_ok" == "false" ]]; then
        log ERROR "Failed to import database $db_name"
        return 1
    fi

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

    local server_ip server_hostname
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    server_hostname=$(hostname 2>/dev/null || echo "localhost")

    mariadb_exec "$container" "panelalpha" "$api_password" panelalpha \
        -e "UPDATE system_settings SET value='$server_ip' WHERE name='host_ip_address';" \
        2>/dev/null && log INFO "Updated host_ip_address: $server_ip" || \
        log WARN "Could not update host_ip_address"

    mariadb_exec "$container" "panelalpha" "$api_password" panelalpha \
        -e "UPDATE system_settings SET value='$server_hostname' WHERE name='trusted_hosts';" \
        2>/dev/null && log INFO "Updated trusted_hosts: $server_hostname" || \
        log WARN "Could not update trusted_hosts"
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

    if [[ -d "$config_panel/ssl/letsencrypt" ]]; then
        log INFO "Restoring SSL certificates..."
        mkdir -p /etc/letsencrypt
        cp -r "$config_panel/ssl/letsencrypt/"* /etc/letsencrypt/ 2>/dev/null || \
            log WARN "SSL restore incomplete"
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

    # Clean only database volumes
    clean_db_volumes "$PANEL_DIR" "database-api-data"

    # Restore panel config
    _restore_config_panel_dir "$data_dir" "$PANEL_DIR" "true"

    # Start only the database container
    log INFO "Starting database-api..."
    dc "$PANEL_DIR" up -d database-api
    wait_for_database_containers "$PANEL_DIR" "database-api" || {
        log ERROR "database-api failed to become ready"
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

    # Application volumes only — do not restore database-api-data (would override SQL)
    for vol in "api-storage" "redis-data"; do
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

    dc "$ENGINE_DIR" ps 2>/dev/null || true
    dc "$PANEL_DIR"  ps 2>/dev/null || true
    log INFO "Single-server restore complete"
}

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

# ======================
# ERROR HANDLER
# ======================

error_handler() {
    local exit_code=$?
    local line_number="${1:-unknown}"
    log ERROR "Unexpected error at line $line_number (exit code: $exit_code)"
    log ERROR "Check logs: /var/log/pasnap.log"
    cleanup_temp_dir
    exit "$exit_code"
}

trap 'error_handler $LINENO' ERR

# ======================
# INITIALIZATION
# ======================

detect_installation
load_configuration

# ======================
# MAIN ENTRY POINT
# ======================

main() {
    if [[ "${1:-}" == "--update" ]]; then
        log INFO "Forcing update check..."
        PASNAP_SKIP_UPDATE_CHECK=0 \
        PASNAP_FORCE_UPDATE_CHECK=1 \
        PASNAP_AUTO_UPDATE=1 \
        PASNAP_DISABLE_AUTO_UPDATE=0 \
            check_for_updates "$@"
        exit 0
    fi

    check_for_updates "$@"

    if [[ $# -eq 0 ]]; then
        echo "$SCRIPT_NAME v$SCRIPT_VERSION"
        echo ""
        echo "No arguments provided. Use --help for options."
        echo ""
        echo "Quick start:"
        echo "  1. sudo $0 --install     # Install required tools"
        echo "  2. sudo $0 --setup       # Configure snapshot repository"
        echo "  3. sudo $0 --snapshot    # Create first snapshot"
        echo "  Or:  sudo $0 --quickstart  # All three in one step"
        echo ""
        echo "Full help: sudo $0 --help"
        exit 0
    fi

    case "${1:-}" in
        --install)
            install_dependencies
            ;;
        --setup)
            setup_config
            ;;
        --quickstart)
            quickstart
            ;;
        --snapshot)
            create_snapshot
            ;;
        --snapshot-bg)
            local bg_log="${LOG_FILE:-/var/log/pasnap.log}"
            nohup bash -c "exec $0 --snapshot" >> "$bg_log" 2>&1 &
            local nohup_pid=$!
            disown "$nohup_pid" 2>/dev/null || true
            sleep 0.5
            local bg_pid=""
            bg_pid=$(pgrep -P "$nohup_pid" 2>/dev/null || echo "")
            [[ -z "$bg_pid" ]] && bg_pid="$nohup_pid"
            log INFO "Snapshot started in background (PID: $bg_pid)"
            log INFO "Process continues even if terminal closes"
            log INFO "Monitor progress: tail -f $bg_log"
            ;;
        --test-connection)
            test_repository_connection
            ;;
        --verify-database)
            verify_database_connections
            ;;
        --restore)
            if [[ -z "${2:-}" ]]; then
                log ERROR "Snapshot ID required"
                log ERROR "Usage: $0 --restore <snapshot_id|latest>"
                log ERROR "Use '$0 --list-snapshots' to see available snapshots"
                exit 1
            fi
            if [[ "$2" != "latest" ]]; then
                validate_input "$2" "snapshot_id" || exit 1
            fi
            restore_from_snapshot "$2"
            ;;
        --list-snapshots)
            list_snapshots
            ;;
        --delete-snapshots)
            if [[ -z "${2:-}" ]]; then
                log ERROR "Snapshot ID required"
                log ERROR "Usage: $0 --delete-snapshots <snapshot_id>"
                exit 1
            fi
            validate_input "$2" "snapshot_id" || exit 1
            delete_snapshot "$2"
            ;;
        --cron)
            if [[ -z "${2:-}" ]] || [[ ! "${2:-}" =~ ^(install|remove|status)$ ]]; then
                log ERROR "Usage: $0 --cron [install|remove|status]"
                exit 1
            fi
            manage_cron "$2"
            ;;
        --version)
            show_version
            ;;
        --help|-h)
            show_help
            ;;
        *)
            log ERROR "Unknown option: ${1:-}"
            echo ""
            echo "Use '$0 --help' to see available options"
            echo ""
            echo "Common commands:"
            echo "  sudo $0 --snapshot         # Create snapshot"
            echo "  sudo $0 --list-snapshots   # View snapshots"
            echo "  sudo $0 --restore latest   # Restore latest"
            exit 1
            ;;
    esac
}

main "$@"
