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

