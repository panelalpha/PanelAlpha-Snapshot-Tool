#!/bin/bash

# PanelAlpha Snapshot & Restore Tool
# Automated backup and disaster recovery solution for PanelAlpha Control Panel and Engine
# Usage: ./pasnap.sh [options]

set -euo pipefail

# ======================
# CONFIGURATION CONSTANTS
# ======================

readonly SCRIPT_VERSION="1.2.1"
readonly SCRIPT_NAME="PanelAlpha Snapshot & Restore Tool"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure cron runs have access to standard system binaries.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# Detect PanelAlpha installation type and set paths accordingly
detect_panelalpha_type() {
    if [[ -d "/opt/panelalpha/shared-hosting" && -f "/opt/panelalpha/shared-hosting/docker-compose.yml" ]]; then
        echo "engine"
    elif [[ -d "/opt/panelalpha/engine" && -f "/opt/panelalpha/engine/docker-compose.yml" ]]; then
        echo "engine"
    elif [[ -d "/opt/panelalpha/app" && -f "/opt/panelalpha/app/docker-compose.yml" ]]; then
        echo "app"
    else
        echo "unknown"
    fi
}

readonly PANELALPHA_APP_TYPE="$(detect_panelalpha_type)"

# Global configuration directory
readonly CONFIG_DIR="/opt/panelalpha/pasnap"
readonly CONFIG_FILE="${CONFIG_DIR}/.env-backup"

# Resolve PanelAlpha directory and environment file for the detected type
PANELALPHA_DIR=""
ENV_FILE=""
ENV_FILE_NAME=""

if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
    engine_candidates=("/opt/panelalpha/shared-hosting" "/opt/panelalpha/engine")
    for candidate in "${engine_candidates[@]}"; do
        if [[ -d "$candidate" && -f "$candidate/docker-compose.yml" ]]; then
            PANELALPHA_DIR="$candidate"
            break
        fi
    done

    if [[ -z "$PANELALPHA_DIR" ]]; then
        PANELALPHA_DIR="/opt/panelalpha/shared-hosting"
    fi

    if [[ -f "$PANELALPHA_DIR/.env" ]]; then
        ENV_FILE="$PANELALPHA_DIR/.env"
        ENV_FILE_NAME=".env"
    elif [[ -f "$PANELALPHA_DIR/.env-core" ]]; then
        ENV_FILE="$PANELALPHA_DIR/.env-core"
        ENV_FILE_NAME=".env-core"
    else
        ENV_FILE="$PANELALPHA_DIR/.env"
        ENV_FILE_NAME=".env"
    fi
elif [[ "$PANELALPHA_APP_TYPE" == "app" ]]; then
    PANELALPHA_DIR="/opt/panelalpha/app"
    ENV_FILE="$PANELALPHA_DIR/.env"
    ENV_FILE_NAME=".env"
else
    # Default to app for backward compatibility
    PANELALPHA_DIR="/opt/panelalpha/app"
    ENV_FILE="$PANELALPHA_DIR/.env"
    ENV_FILE_NAME=".env"
fi

readonly PANELALPHA_DIR
readonly ENV_FILE
readonly ENV_FILE_NAME

# Security constants
readonly MYSQL_TIMEOUT=30
readonly MAX_RETRY_ATTEMPTS=3
readonly CORE_DUMP_TIMEOUT="${PASNAP_CORE_DUMP_TIMEOUT:-600}"
readonly USERS_DUMP_TIMEOUT="${PASNAP_USERS_DUMP_TIMEOUT:-1800}"
readonly USERS_DUMP_COMPRESSION_LEVEL="${PASNAP_USERS_DUMP_COMPRESSION_LEVEL:-1}"
readonly VOLUME_SNAPSHOT_TIMEOUT="${PASNAP_VOLUME_SNAPSHOT_TIMEOUT:-7200}"
readonly USERS_HOME_SNAPSHOT_TIMEOUT="${PASNAP_USERS_HOME_SNAPSHOT_TIMEOUT:-14400}"

# Color constants for logging
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m'

# ======================
# SECURITY AND VALIDATION FUNCTIONS
# ======================

# Validate and sanitize input parameters
validate_input() {
    local input="$1"
    local type="$2"
    
    case "$type" in
        "snapshot_id")
            if [[ ! "$input" =~ ^[a-zA-Z0-9]{8}$|^latest$ ]]; then
                log ERROR "Invalid snapshot ID format: $input"
                return 1
            fi
            ;;
        "path")
            if [[ "$input" =~ \.\.|^/dev/|^/sys/|^/proc/ ]]; then
                log ERROR "Invalid path: $input"
                return 1
            fi
            ;;
        "hour")
            if ! [[ "$input" =~ ^[0-9]+$ ]] || [[ $input -lt 0 ]] || [[ $input -gt 23 ]]; then
                log ERROR "Invalid hour: $input (must be 0-23)"
                return 1
            fi
            ;;
        "retention_days")
            if ! [[ "$input" =~ ^[0-9]+$ ]] || [[ $input -lt 1 ]] || [[ $input -gt 365 ]]; then
                log ERROR "Invalid retention days: $input (must be 1-365)"
                return 1
            fi
            ;;
    esac
    return 0
}

# Securely execute MySQL commands using temporary files instead of command line
secure_mysql_exec() {
    local container="$1"
    local username="$2"
    local password="$3"
    local database="$4"
    local sql_command="$5"
    
    # Create temporary file for MySQL config
    local temp_config
    temp_config=$(mktemp)
    chmod 600 "$temp_config"
    
    # Write MySQL configuration to temp file
    cat > "$temp_config" << EOF
[client]
user=$username
password=$password
EOF

    # Execute command with timeout and cleanup
    local result=0
    if timeout "$MYSQL_TIMEOUT" docker exec -i "$container" mysql --defaults-file=<(cat "$temp_config") "$database" <<< "$sql_command" 2>/dev/null; then
        result=0
    else
        result=1
    fi
    
    # Cleanup
    rm -f "$temp_config"
    return $result
}

# Verify file integrity
verify_file_integrity() {
    local file_path="$1"
    local min_size="${2:-100}"
    
    if [[ ! -f "$file_path" ]]; then
        log ERROR "File does not exist: $file_path"
        return 1
    fi
    
    if [[ ! -r "$file_path" ]]; then
        log ERROR "File is not readable: $file_path"
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

# ======================
# ENHANCED LOGGING FUNCTIONS
# ======================

# Log messages with timestamp and appropriate formatting
# Usage: log LEVEL "message"
log_file_matches_fd() {
    local log_path="$1"
    local fd="$2"
    local log_stat
    local fd_stat

    log_stat=$(stat -Lc '%d:%i' "$log_path" 2>/dev/null || true)
    fd_stat=$(stat -Lc '%d:%i' "/proc/$$/fd/$fd" 2>/dev/null || true)

    [[ -n "$log_stat" && "$log_stat" == "$fd_stat" ]]
}

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case $level in
        INFO)  echo -e "${COLOR_GREEN}[$timestamp] INFO:${COLOR_NC} $message" ;;
        WARN)  echo -e "${COLOR_YELLOW}[$timestamp] WARN:${COLOR_NC} $message" >&2 ;;
        ERROR) echo -e "${COLOR_RED}[$timestamp] ERROR:${COLOR_NC} $message" >&2 ;;
        DEBUG) echo -e "${COLOR_BLUE}[$timestamp] DEBUG:${COLOR_NC} $message" ;;
        *)     echo -e "[$timestamp] $level: $message" ;;
    esac
    
    # Also log to file if LOG_FILE is set and writable and not already redirected there
    if [[ -n "${LOG_FILE:-}" ]] && [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]]; then
        if ! log_file_matches_fd "$LOG_FILE" 1 && ! log_file_matches_fd "$LOG_FILE" 2; then
            echo "[$timestamp] $level: $message" >> "$LOG_FILE"
        fi
    fi
}

# Progress indicator for long operations
show_progress() {
    local current="$1"
    local total="$2"
    local description="$3"
    
    local percentage=$((current * 100 / total))
    local completed=$((current * 50 / total))
    local remaining=$((50 - completed))
    
    printf "\r%s [" "$description"
    printf "%*s" $completed | tr ' ' '█'
    printf "%*s" $remaining | tr ' ' '░'
    printf "] %d%% (%d/%d)" $percentage $current $total
    
    if [[ $current -eq $total ]]; then
        echo " ✓"
    fi
}

# Monitor database dump progress by checking file size
monitor_dump_progress() {
    local dump_file="$1"
    local description="$2"
    local timeout="${3:-600}"
    
    local start_time=$(date +%s)
    local last_size=0
    local stall_count=0
    
    while [[ -e "$dump_file" ]] || sleep 1; do
        if [[ ! -e "$dump_file" ]]; then
            sleep 2
            continue
        fi
        
        local current_size
        current_size=$(stat -c%s "$dump_file" 2>/dev/null || echo "0")
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Check if we exceeded timeout
        if [[ $elapsed -gt $timeout ]]; then
            printf "\r%s - timeout after %ds\n" "$description" "$elapsed"
            return 1
        fi
        
        # Check if file is growing
        if [[ $current_size -gt $last_size ]]; then
            local size_mb=$((current_size / 1024 / 1024))
            local speed=$((current_size - last_size))
            local speed_mb=$((speed / 1024 / 1024))
            
            if [[ $speed_mb -gt 0 ]]; then
                printf "\r%s - %d MB (%.1f MB/s, %ds)" "$description" "$size_mb" "$speed_mb" "$elapsed"
            else
                printf "\r%s - %d MB (%ds)" "$description" "$size_mb" "$elapsed"
            fi
            
            last_size=$current_size
            stall_count=0
        else
            # File not growing - might be finished or stalled
            ((stall_count++))
            
            if [[ $stall_count -gt 5 ]]; then
                # File hasn't grown for 5 seconds, probably finished
                local size_mb=$((current_size / 1024 / 1024))
                printf "\r%s - %d MB (completed in %ds)\n" "$description" "$size_mb" "$elapsed"
                return 0
            fi
        fi
        
        sleep 1
    done
    
    return 0
}

# Check if script is running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log ERROR "This script must be run as root (use sudo)"
        exit 1
    fi
}

# ======================
# CONFIGURATION LOADING
# ======================

# Load and validate configuration from .env-backup file
load_configuration() {
    # Check for old configuration location and migrate if necessary
    if [[ -f "/opt/panelalpha/app/.env-backup" ]] && [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$(dirname "$CONFIG_FILE")"
        mv "/opt/panelalpha/app/.env-backup" "$CONFIG_FILE"
        log INFO "Migrated configuration from /opt/panelalpha/app/.env-backup to $CONFIG_FILE"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        # Fix (ticket#2060): Remove PANELALPHA_DIR from old config files
        if grep -q "^PANELALPHA_DIR=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i '/^PANELALPHA_DIR=/d' "$CONFIG_FILE" 2>/dev/null || true
            sed -i '/^# PanelAlpha application settings$/d' "$CONFIG_FILE" 2>/dev/null || true
        fi
        
        # shellcheck source=/dev/null
        set -a
        source "$CONFIG_FILE"
        set +a
        log DEBUG "Configuration loaded from $CONFIG_FILE"
    else
        log DEBUG "No configuration file found at $CONFIG_FILE"
    fi

    # Set default values with parameter expansion
    BACKUP_TEMP_DIR="${BACKUP_TEMP_DIR:-/var/tmp}/pasnap-snapshot-$(date +%Y%m%d-%H%M%S)"
    RESTORE_TEMP_DIR="${RESTORE_TEMP_DIR:-/var/tmp}/pasnap-restore-$(date +%Y%m%d-%H%M%S)"
    LOG_FILE="${LOG_FILE:-/var/log/pasnap.log}"
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
    BACKUP_TAG="${BACKUP_TAG_PREFIX:-panelalpha}-$(hostname)"
    RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"
}

# Initialize configuration on script load
load_configuration

# ======================
# VERSION CHECK FUNCTIONS
# ======================

# Check for script updates
check_for_updates() {
    # Skip update check if disabled via environment variable
    if [[ "${PASNAP_SKIP_UPDATE_CHECK:-0}" == "1" ]]; then
        return 0
    fi

    # Only check once per day
    local update_check_file="/var/tmp/.pasnap_last_update_check"
    local current_time=$(date +%s)
    
    if [[ -f "$update_check_file" ]]; then
        local last_check=$(cat "$update_check_file" 2>/dev/null || echo "0")
        local time_diff=$((current_time - last_check))
        # 86400 seconds = 24 hours
        if [[ $time_diff -lt 86400 ]]; then
            return 0
        fi
    fi

    log DEBUG "Checking for updates..."

    # Try to fetch latest version from GitHub
    local remote_version=""
    local github_raw_url="https://raw.githubusercontent.com/panelalpha/PanelAlpha-Snapshot-Tool/main/pasnap.sh"
    
    # Use timeout to prevent hanging
    if command -v curl &> /dev/null; then
        remote_version=$(timeout 5 curl -s "$github_raw_url" 2>/dev/null | grep '^readonly SCRIPT_VERSION=' | cut -d'"' -f2 | head -1)
    elif command -v wget &> /dev/null; then
        remote_version=$(timeout 5 wget -qO- "$github_raw_url" 2>/dev/null | grep '^readonly SCRIPT_VERSION=' | cut -d'"' -f2 | head -1)
    else
        log DEBUG "Neither curl nor wget available, skipping update check"
        return 0
    fi

    # Save current time as last check
    echo "$current_time" > "$update_check_file" 2>/dev/null || true

    # If we couldn't fetch version, silently return
    if [[ -z "$remote_version" ]]; then
        log DEBUG "Could not check for updates (network issue or timeout)"
        return 0
    fi

    # Compare versions
    if [[ "$remote_version" != "$SCRIPT_VERSION" ]]; then
        echo ""
        echo "╔════════════════════════════════════════════════════════════╗"
        echo "║                   UPDATE AVAILABLE                         ║"
        echo "╚════════════════════════════════════════════════════════════╝"
        echo ""
        echo "  Current version: $SCRIPT_VERSION"
        echo "  Latest version:  $remote_version"
        echo ""
        
        # Ask user if they want to update
        read -p "  Do you want to update now? (y/n): " -n 1 -r
        echo ""
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log INFO "Updating script to version $remote_version..."
            
            # Create backup of current script
            local backup_file="${SCRIPT_DIR}/pasnap.sh.backup-$(date +%Y%m%d-%H%M%S)"
            if cp "${SCRIPT_DIR}/pasnap.sh" "$backup_file" 2>/dev/null; then
                log INFO "Backup created: $backup_file"
            else
                log WARN "Could not create backup"
            fi
            
            # Download new version
            local temp_file=$(mktemp)
            if command -v curl &> /dev/null; then
                if curl -sL "$github_raw_url" -o "$temp_file" 2>/dev/null; then
                    # Verify download
                    if [[ -s "$temp_file" ]] && grep -q "SCRIPT_VERSION" "$temp_file"; then
                        if mv "$temp_file" "${SCRIPT_DIR}/pasnap.sh" 2>/dev/null; then
                            chmod +x "${SCRIPT_DIR}/pasnap.sh"
                            echo ""
                            log INFO "✓ Update successful! Script updated to version $remote_version"
                            log INFO "Previous version backed up to: $backup_file"
                            echo ""
                            log INFO "Restarting script with new version..."
                            echo ""
                            sleep 2
                            # Re-execute script with same arguments
                            exec "${SCRIPT_DIR}/pasnap.sh" "$@"
                        else
                            log ERROR "Failed to replace script file (permission denied?)"
                            rm -f "$temp_file"
                        fi
                    else
                        log ERROR "Downloaded file appears corrupted"
                        rm -f "$temp_file"
                    fi
                else
                    log ERROR "Failed to download update"
                    rm -f "$temp_file"
                fi
            elif command -v wget &> /dev/null; then
                if wget -q "$github_raw_url" -O "$temp_file" 2>/dev/null; then
                    # Verify download
                    if [[ -s "$temp_file" ]] && grep -q "SCRIPT_VERSION" "$temp_file"; then
                        if mv "$temp_file" "${SCRIPT_DIR}/pasnap.sh" 2>/dev/null; then
                            chmod +x "${SCRIPT_DIR}/pasnap.sh"
                            echo ""
                            log INFO "✓ Update successful! Script updated to version $remote_version"
                            log INFO "Previous version backed up to: $backup_file"
                            echo ""
                            log INFO "Restarting script with new version..."
                            echo ""
                            sleep 2
                            # Re-execute script with same arguments
                            exec "${SCRIPT_DIR}/pasnap.sh" "$@"
                        else
                            log ERROR "Failed to replace script file (permission denied?)"
                            rm -f "$temp_file"
                        fi
                    else
                        log ERROR "Downloaded file appears corrupted"
                        rm -f "$temp_file"
                    fi
                else
                    log ERROR "Failed to download update"
                    rm -f "$temp_file"
                fi
            else
                log ERROR "Neither curl nor wget available for update"
            fi
        else
            echo ""
            log INFO "Update skipped. To update manually, run:"
            echo "  cd $SCRIPT_DIR"
            echo "  wget -O pasnap.sh $github_raw_url"
            echo "  chmod +x pasnap.sh"
            echo ""
            log INFO "To skip update check, set: export PASNAP_SKIP_UPDATE_CHECK=1"
            echo ""
            sleep 2
        fi
    else
        log DEBUG "Script is up to date (version $SCRIPT_VERSION)"
    fi

    return 0
}

# ======================
# MAIN FUNCTIONS
# ======================

# ======================
# HELP AND VERSION FUNCTIONS
# ======================

show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION
Supports both PanelAlpha Control Panel and Engine

🚀 USAGE: $0 [option]

📦 INSTALLATION AND CONFIGURATION:
  --install             Install all required tools
  --setup               Interactive configuration (repository, authentication)

📸 SNAPSHOT OPERATIONS:
  --snapshot            Create new snapshot
  --snapshot-bg         Create new snapshot in background
  --test-connection     Test repository connection

🔄 RESTORE OPERATIONS:
  --restore <snapshot>  Restore complete backup from snapshot
  --list-snapshots      Show all available snapshots
  --delete-snapshots <id> Delete specific snapshot by ID

🤖 AUTOMATION:
  --cron [install|remove|status]  Manage automatic snapshot creation

ℹ️  OTHER:
  --help, -h            Show this help
  --version             Show version information

💡 EXAMPLES:
  $0 --install                   # Install tools
  $0 --setup                     # Configure snapshot settings
  $0 --snapshot                  # Create snapshot
  $0 --snapshot-bg               # Create snapshot in background
  $0 --test-connection           # Test repository connection
  $0 --restore latest            # Restore latest snapshot
  $0 --restore a1b2c3d4          # Restore specific snapshot
  $0 --list-snapshots            # Show available snapshots
  $0 --delete-snapshots a1b2c3d4 # Delete specific snapshot
  $0 --cron install              # Set up automatic snapshots
  $0 --cron status               # Check automation status

🔧 SYSTEM REQUIREMENTS:
  - Ubuntu 18.04+ or compatible Linux
  - Docker 20.10+
  - Docker Compose 1.29+
  - Minimum 3GB free space
  - Root permissions (sudo)

📁 Configuration file: $CONFIG_FILE

⚠️  IMPORTANT:
  - Always run with sudo
  - Test restoration on test environment
  - Regularly check snapshot integrity

🆘 HELP:
  For issues check logs: /var/log/pasnap.log
  
EOF
}

show_version() {
    echo "🚀 $SCRIPT_NAME v$SCRIPT_VERSION"
    echo "Professional solution for creating snapshots and restoring PanelAlpha"
    echo "Supports both Control Panel and Engine"
    echo "Uses Restic for secure, incremental backups"
    echo ""
    echo "📋 DETECTED APPLICATION:"
    if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
        echo "  - Type: PanelAlpha Engine"
        echo "  - Path: $PANELALPHA_DIR"
    elif [[ "$PANELALPHA_APP_TYPE" == "app" ]]; then
        echo "  - Type: PanelAlpha Control Panel"
        echo "  - Path: $PANELALPHA_DIR"
    else
        echo "  - Type: Not detected (will use default: Control Panel)"
        echo "  - Path: $PANELALPHA_DIR"
    fi
    echo ""
    echo "📋 COMPONENTS:"
    echo "  - Snapshot tool: $SCRIPT_VERSION"
    if command -v restic &> /dev/null; then
        echo "  - Restic: $(restic version 2>/dev/null | head -1 || echo 'unknown')"
    fi
    if command -v docker &> /dev/null; then
        echo "  - Docker: $(docker --version 2>/dev/null || echo 'unknown')"
    fi
    echo ""
    echo "🏠 SYSTEM:"
    echo "  - OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown Linux')"
    echo "  - Kernel: $(uname -r)"
    echo "  - Architecture: $(uname -m)"
    echo ""
    echo "Copyright (c) $(date +%Y) - Apache-2.0 license"
    echo "More information in README.md file"
}

# ======================
# DEPENDENCY MANAGEMENT
# ======================

# Install all required dependencies for the snapshot system
install_dependencies() {
    log INFO "=== Installing Dependencies ==="

    check_root

    # Display system information
    log INFO "System: $(lsb_release -d 2>/dev/null | cut -f2 || echo "Unknown Linux")"
    log INFO "Architecture: $(uname -m)"
    log INFO "Kernel: $(uname -r)"

    # Update package list
    log INFO "Updating package list..."
    if ! apt update >/dev/null 2>&1; then
        log ERROR "Failed to update package list"
        log ERROR "Please check your internet connection and repository configuration"
        exit 1
    fi

    local packages_to_install=()
    local packages_status=()

    # Check and prepare Restic installation
    if ! command -v restic &> /dev/null; then
        log INFO "Restic not found - will install from official repository"
        packages_to_install+=("restic")
        packages_status+=("restic: will install")
    else
        local restic_version
        restic_version=$(restic version 2>/dev/null | head -1 || echo "unknown")
        log INFO "Restic is already installed ✓ ($restic_version)"
        packages_status+=("restic: already installed")
    fi

    # Check jq
    if ! command -v jq &> /dev/null; then
        packages_to_install+=("jq")
        packages_status+=("jq: will install")
    else
        local jq_version
        jq_version=$(jq --version 2>/dev/null || echo "unknown")
        log INFO "jq is already installed ✓ ($jq_version)"
        packages_status+=("jq: already installed")
    fi

    # Check rsync
    if ! command -v rsync &> /dev/null; then
        packages_to_install+=("rsync")
        packages_status+=("rsync: will install")
    else
        local rsync_version
        rsync_version=$(rsync --version 2>/dev/null | head -1 || echo "unknown")
        log INFO "rsync is already installed ✓ ($rsync_version)"
        packages_status+=("rsync: already installed")
    fi

    # Install missing packages
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        log INFO "Installing packages: ${packages_to_install[*]}"
        
        local retry_count=0
        while [[ $retry_count -lt $MAX_RETRY_ATTEMPTS ]]; do
            if apt install -y "${packages_to_install[@]}" >/dev/null 2>&1; then
                log INFO "All packages installed successfully ✓"
                break
            else
                ((retry_count++))
                if [[ $retry_count -lt $MAX_RETRY_ATTEMPTS ]]; then
                    log WARN "Package installation failed, retrying ($retry_count/$MAX_RETRY_ATTEMPTS)..."
                    sleep 5
                else
                    log ERROR "Failed to install packages after $MAX_RETRY_ATTEMPTS attempts"
                    exit 1
                fi
            fi
        done
    else
        log INFO "All required packages are already installed ✓"
    fi

    # Verify Docker installation
    if ! command -v docker &> /dev/null; then
        log ERROR "Docker is not installed"
        log ERROR "Please install Docker first: https://docs.docker.com/engine/install/"
        log ERROR "Required for PanelAlpha operation"
        exit 1
    else
        local docker_version
        docker_version=$(docker --version 2>/dev/null || echo "unknown")
        log INFO "Docker is available ✓ ($docker_version)"
    fi

    # Verify Docker Compose installation
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log ERROR "Docker Compose is not available"
        log ERROR "Please install Docker Compose: https://docs.docker.com/compose/install/"
        log ERROR "Required for PanelAlpha operation"
        exit 1
    else
        local compose_version
        if command -v docker-compose &> /dev/null; then
            compose_version=$(docker-compose --version 2>/dev/null || echo "unknown")
        else
            compose_version=$(docker compose version --short 2>/dev/null || echo "unknown")
        fi
        log INFO "Docker Compose is available ✓ ($compose_version)"
    fi

    # Final verification - test all installed tools
    log INFO "=== Final Verification ==="
    for status in "${packages_status[@]}"; do
        log INFO "  $status"
    done

    log INFO "=== Dependencies installation completed ✓ ==="
    log INFO "You can now proceed with: $0 --setup"
}

# ======================
# SYSTEM VALIDATION
# ======================

# Comprehensive system requirements check
check_requirements() {
    log INFO "Performing system requirements check..."

    check_root

    # Validate configuration file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log ERROR "Configuration file not found: $CONFIG_FILE"
        log ERROR "Please run: $0 --setup"
        exit 1
    fi

    # Validate Restic installation
    if ! command -v restic &> /dev/null; then
        log ERROR "Restic is not installed"
        log ERROR "Please run: $0 --install"
        exit 1
    fi

    # Validate Docker service
    if ! docker info &> /dev/null; then
        log ERROR "Docker daemon is not running"
        log ERROR "Please start Docker service: systemctl start docker"
        exit 1
    fi

    # Validate Docker Compose availability
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log ERROR "Docker Compose is not available"
        log ERROR "Please install Docker Compose"
        exit 1
    fi

    # Check PanelAlpha installation
    if [[ ! -d "$PANELALPHA_DIR" ]]; then
        log ERROR "PanelAlpha directory not found: $PANELALPHA_DIR"
        exit 1
    fi

    # Validate PanelAlpha containers (if docker-compose.yml exists)
    if [[ -f "$PANELALPHA_DIR/docker-compose.yml" ]]; then
        cd "$PANELALPHA_DIR"
        local running_containers
        running_containers=$(docker-compose ps --quiet 2>/dev/null || docker compose ps --quiet 2>/dev/null || echo "")
        
        if [[ -n "$running_containers" ]]; then
            log INFO "PanelAlpha containers are running ✓"
        else
            log WARN "PanelAlpha containers are not running"
            log WARN "This is acceptable for restore operations on new servers"
        fi
    else
        log INFO "No docker-compose.yml found - skipping container check"
    fi

    # Validate repository configuration
    validate_repository_config

    # Check system resources
    check_system_resources

    # Initialize required directories
    create_required_directories

    # Test repository connectivity
    test_repository_connectivity

    log INFO "All system requirements satisfied ✓"
}

# Validate repository configuration variables
validate_repository_config() {
    if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD:-}" ]]; then
        log ERROR "RESTIC_REPOSITORY and RESTIC_PASSWORD must be configured"
        log ERROR "Please run: $0 --setup"
        exit 1
    fi

    # Export AWS credentials if configured
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
        export AWS_ACCESS_KEY_ID
    fi
    if [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        export AWS_SECRET_ACCESS_KEY
    fi
}

# Check available system resources
check_system_resources() {
    log INFO "Checking system resources..."

    local temp_dir_parent
    temp_dir_parent="$(dirname "$BACKUP_TEMP_DIR")"

    # Check disk space for temporary operations
    local available_space_mb
    available_space_mb=$(df "$temp_dir_parent" | awk 'NR==2 {print int($4/1024)}') || {
        log WARN "Could not determine available disk space"
        return 0
    }

    # Estimate space requirements (databases + volumes + config + buffer)
    local required_space_mb=3000

    log INFO "Available space: ${available_space_mb}MB, Required: ~${required_space_mb}MB"

    if [[ $available_space_mb -lt $required_space_mb ]]; then
        log ERROR "Insufficient disk space in temporary directory"
        log ERROR "Available: ${available_space_mb}MB, Required: ${required_space_mb}MB"
        log ERROR "Please free up space in $temp_dir_parent"
        exit 1
    fi

    log INFO "Disk space check passed ✓"
}

# Create necessary directories with proper permissions
create_required_directories() {
    local dirs=(
        "$RESTIC_CACHE_DIR"
        "$(dirname "$LOG_FILE")"
    )

    for dir in "${dirs[@]}"; do
        if ! mkdir -p "$dir"; then
            log ERROR "Failed to create directory: $dir"
            exit 1
        fi
    done

    export RESTIC_CACHE_DIR
}

test_repository_connectivity() {
    log INFO "Testing repository connectivity..."

    # Check if repository is initialized
    if ! restic -r "$RESTIC_REPOSITORY" snapshots &> /dev/null; then
        log INFO "Repository not initialized. Initializing..."
        if ! restic -r "$RESTIC_REPOSITORY" init; then
            log ERROR "Failed to initialize repository"
            log ERROR "Check your repository URL and credentials"
            exit 1
        fi
        log INFO "Repository initialized successfully"
    else
        log INFO "Repository connectivity test passed ✓"
    fi
}

test_repository_connection() {
    log INFO "=== Testing Repository Connection ==="

    check_root

    # Check if config file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log ERROR "Configuration file not found: $CONFIG_FILE"
        log ERROR "Run: $0 --setup first"
        exit 1
    fi

    # Load configuration
    source "$CONFIG_FILE"

    # Check required configuration
    if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD:-}" ]]; then
        log ERROR "RESTIC_REPOSITORY and RESTIC_PASSWORD must be set"
        log ERROR "Run: $0 --setup to configure"
        exit 1
    fi

    # Export AWS credentials if set
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
        export AWS_ACCESS_KEY_ID
    fi
    if [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        export AWS_SECRET_ACCESS_KEY
    fi

    # Check if Restic is installed
    if ! command -v restic &> /dev/null; then
        log ERROR "Restic is not installed"
        log ERROR "Run: $0 --install to install dependencies"
        exit 1
    fi

    # Create cache directory
    mkdir -p "$RESTIC_CACHE_DIR"
    export RESTIC_CACHE_DIR

    log INFO "Repository: $RESTIC_REPOSITORY"
    log INFO "Testing connection..."

    # Test repository access
    if restic -r "$RESTIC_REPOSITORY" snapshots &> /dev/null; then
        log INFO "✓ Repository connection successful"

        # Show basic repository info
        local snapshot_count=$(restic -r "$RESTIC_REPOSITORY" snapshots --json 2>/dev/null | jq '. | length' 2>/dev/null || echo "0")
        log INFO "✓ Found $snapshot_count snapshots in repository"

        return 0
    else
        log INFO "Repository not initialized, attempting to initialize..."
        if restic -r "$RESTIC_REPOSITORY" init; then
            log INFO "✓ Repository initialized successfully"
            return 0
        else
            log ERROR "✗ Failed to connect to or initialize repository"
            log ERROR "Please check your configuration and credentials"
            return 1
        fi
    fi
}

setup_config() {
    log INFO "=== SNAPSHOT REPOSITORY CONFIGURATION ==="

    check_root

    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Configuration file already exists: $CONFIG_FILE"
        read -p "Do you want to overwrite it? (yes/no): " overwrite
        if [[ "$overwrite" != "yes" ]]; then
            log INFO "Configuration was cancelled"
            return 0
        fi
    fi

    echo "Configure snapshot repository settings:"
    echo
    echo "Available storage types:"
    echo "  local - local storage (on the same server)"
    echo "  sftp  - remote server via SFTP/SSH"
    echo "  s3    - cloud storage (AWS, Hetzner, others)"
    echo

    while true; do
        read -p "Repository type (local/sftp/s3): " repo_type
        if [[ "$repo_type" =~ ^(local|sftp|s3)$ ]]; then
            break
        fi
        echo "Invalid type. Choose: local, sftp or s3"
    done

    case $repo_type in
        local)
            echo
            echo "=== LOCAL STORAGE ==="
            echo "Snapshots will be stored locally on this server."
            echo "WARNING: In case of server failure, snapshots may be lost."
            echo
            while true; do
                read -p "Path to snapshot directory (e.g. /backup/panelalpha): " backup_path
                if validate_input "$backup_path" "path"; then
                    break
                fi
            done
            
            RESTIC_REPO="$backup_path"
            
            if ! mkdir -p "$backup_path"; then
                log ERROR "Cannot create directory: $backup_path"
                exit 1
            fi

            # Set proper permissions
            chmod 700 "$backup_path"
            log INFO "✓ Directory created with secure permissions"

            AWS_ACCESS_KEY=""
            AWS_SECRET_KEY=""
            ;;
        sftp)
            echo
            echo "=== SFTP STORAGE ==="
            echo "Snapshots will be stored on remote server via SFTP."
            echo "SSH access to remote server is required."
            echo
    read -p "SFTP username: " sftp_user
            while [[ -z "$sftp_user" ]]; do
                echo "Username cannot be empty"
                read -p "SFTP username: " sftp_user
            done
            
            read -p "SFTP server address: " sftp_host
            while [[ -z "$sftp_host" ]]; do
                echo "Server address cannot be empty"
                read -p "SFTP server address: " sftp_host
            done
            
            read -p "Remote path (e.g. /backup/panelalpha): " sftp_path
            while [[ -z "$sftp_path" ]]; do
                echo "Path cannot be empty"
                read -p "Remote path (e.g. /backup/panelalpha): " sftp_path
            done
            
            RESTIC_REPO="sftp:${sftp_user}@${sftp_host}:${sftp_path}"

            AWS_ACCESS_KEY=""
            AWS_SECRET_KEY=""
            
            echo
            echo "WARNING: Make sure you have configured passwordless SSH access"
            echo "or that SSH key is available for root user."
            ;;
        s3)
            echo
            echo "=== S3 STORAGE ==="
            echo "Compatible with AWS S3, Hetzner Storage, MinIO, DigitalOcean Spaces"
            echo
            read -p "Access Key ID: " s3_access_key
            while [[ -z "$s3_access_key" ]]; do
                echo "Access Key ID cannot be empty"
                read -p "Access Key ID: " s3_access_key
            done
            
            read -s -p "Secret Access Key: " s3_secret_key
            echo
            while [[ -z "$s3_secret_key" ]]; do
                echo "Secret Access Key cannot be empty"
                read -s -p "Secret Access Key: " s3_secret_key
                echo
            done
            
            read -p "Region (e.g. eu-west-1, us-east-1): " s3_region
            while [[ -z "$s3_region" ]]; do
                echo "Region cannot be empty"
                read -p "Region (e.g. eu-west-1, us-east-1): " s3_region
            done
            
            read -p "Bucket name: " s3_bucket
            while [[ -z "$s3_bucket" ]]; do
                echo "Bucket name cannot be empty"
                read -p "Bucket name: " s3_bucket
            done
            read -p "S3 Endpoint (leave empty for AWS, or enter e.g. s3.hetzner.cloud): " s3_endpoint
            read -p "Path prefix in bucket (e.g. pasnap): " s3_prefix
            s3_prefix=${s3_prefix:-pasnap}

            # Validate input
            if [[ -z "$s3_access_key" || -z "$s3_secret_key" || -z "$s3_bucket" ]]; then
                log ERROR "Access Key, Secret Key and bucket name are required"
                exit 1
            fi

            # Construct repository URL
            if [[ -n "$s3_endpoint" ]]; then
                s3_endpoint=${s3_endpoint#https://}
                s3_endpoint=${s3_endpoint#http://}
                RESTIC_REPO="s3:${s3_endpoint}/${s3_bucket}/${s3_prefix}"
            else
                RESTIC_REPO="s3:s3.${s3_region}.amazonaws.com/${s3_bucket}/${s3_prefix}"
            fi

            AWS_ACCESS_KEY="$s3_access_key"
            AWS_SECRET_KEY="$s3_secret_key"
            ;;
    esac

    echo
    while true; do
        read -s -p "Repository encryption password: " restic_password
        echo
        if [[ ${#restic_password} -lt 8 ]]; then
            echo "Password must be at least 8 characters long"
            continue
        fi
        read -s -p "Confirm password: " restic_password_confirm
        echo
        if [[ "$restic_password" == "$restic_password_confirm" ]]; then
            break
        fi
        echo "Passwords do not match. Try again."
    done

    echo
    while true; do
        read -p "Snapshot retention period (days, default 30): " retention_days
        retention_days=${retention_days:-30}
        if validate_input "$retention_days" "retention_days"; then
            break
        fi
    done

    echo
    while true; do
        read -p "Automatic snapshot hour (0-23, default 2 for 2:00 AM): " backup_hour
        backup_hour=${backup_hour:-2}
        if validate_input "$backup_hour" "hour"; then
            break
        fi
    done

    # Create configuration directory if it doesn't exist
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR"
        chmod 700 "$CONFIG_DIR"
    fi

    # Create configuration file with proper permissions
    cat > "$CONFIG_FILE" << EOF
# PanelAlpha Snapshot Configuration
# Generated: $(date)
# Version: $SCRIPT_VERSION

# Repository settings
RESTIC_REPOSITORY="$RESTIC_REPO"
RESTIC_PASSWORD="$restic_password"

# S3 credentials (if applicable)
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

    # Secure the configuration file
    chmod 600 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"
    log INFO "✓ Configuration saved securely: $CONFIG_FILE"

    # Test repository connection
    log INFO "Testing repository connection..."
    if test_repository_connection; then
        log INFO "✓ Repository connection test successful"
        log INFO "✓ Configuration completed"
        echo
        echo "Next steps:"
        echo "1. Create first snapshot: $0 --snapshot"
        echo "2. Configure automatic snapshots: $0 --cron install"
    else
        log WARN "Repository connection test failed"
        log WARN "Check settings and try again"
        return 1
    fi
}

# ======================
# SNAPSHOT CREATION FUNCTIONS
# ======================

# Create databases snapshot with enhanced security
create_database_snapshot() {
    log INFO "Creating database snapshots..."

    local snapshot_dir="$1"
    mkdir -p "$snapshot_dir/databases"

    cd "$PANELALPHA_DIR"

    local snapshot_success=true

    # Handle different database configurations based on application type
    if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
        log INFO "Detected PanelAlpha Engine - backing up core and users databases"
        
        # Extract database passwords from environment file securely
        local core_password
        local users_password
        core_password=$(grep "^CORE_MYSQL_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | head -1 || echo "")
        users_password=$(grep "^USERS_MYSQL_ROOT_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | head -1 || echo "")

        local total_steps=2
        local current_step=0

        # Snapshot Core database
        if [[ -n "$core_password" ]]; then
            ((current_step++))
            show_progress $current_step $total_steps "Creating Core database snapshot"
            
            local core_container
            core_container=$(docker compose ps -q database-core 2>/dev/null)

            if [[ -z "$core_container" ]]; then
                log ERROR "Core database container not found"
                snapshot_success=false
            else
                # Test database connectivity with timeout
                if timeout "$MYSQL_TIMEOUT" docker exec "$core_container" mysql -u core -p"$core_password" -e "SELECT 1;" >/dev/null 2>&1; then
                    log DEBUG "Core database connection verified"

                    # Create database dump with enhanced options and error checking
                    local dump_file="$snapshot_dir/databases/panelalpha-core.sql"
                    
                    # Start dump in background and monitor progress
                    timeout "$CORE_DUMP_TIMEOUT" docker exec "$core_container" \
                        mysqldump -u core -p"$core_password" core \
                        --single-transaction --routines --triggers --lock-tables=false \
                        --add-drop-database --create-options --disable-keys \
                        --extended-insert --quick --set-charset \
                        > "$dump_file" 2>/dev/null &
                    local dump_pid=$!
                    
                    # Monitor progress while dump is running
                    log INFO "Creating Core database dump..."
                    monitor_dump_progress "$dump_file" "Core database dump" "$CORE_DUMP_TIMEOUT" &
                    local monitor_pid=$!
                    
                    # Wait for dump to complete
                    if wait $dump_pid; then
                        kill $monitor_pid 2>/dev/null || true
                        wait $monitor_pid 2>/dev/null || true
                        
                        # Verify snapshot file integrity
                        if verify_file_integrity "$dump_file" 1000; then
                            local core_size
                            core_size=$(stat -c%s "$dump_file" 2>/dev/null || echo "0")
                            log INFO "✓ Core database snapshot created ($(( core_size / 1024 )) KB)"
                        else
                            log ERROR "✗ Core database snapshot is corrupted"
                            snapshot_success=false
                        fi
                    else
                        kill $monitor_pid 2>/dev/null || true
                        wait $monitor_pid 2>/dev/null || true
                        log ERROR "✗ Core database snapshot failed"
                        snapshot_success=false
                    fi
                else
                    log ERROR "✗ Cannot connect to Core database"
                    log ERROR "Check database password in $ENV_FILE file"
                    snapshot_success=false
                fi
            fi
        else
            log WARN "CORE_MYSQL_PASSWORD not found - skipping Core database"
            current_step=$total_steps
        fi

        # Snapshot Users database (all databases from users container)
        if [[ -n "$users_password" ]]; then
            if [[ -n "$core_password" ]]; then
                ((current_step++))
            else
                current_step=$total_steps
            fi
            show_progress $current_step $total_steps "Creating Users databases snapshot"
            
            local users_container
            users_container=$(docker compose ps -q database-users 2>/dev/null)

            if [[ -z "$users_container" ]]; then
                log ERROR "Users database container not found"
                snapshot_success=false
            else
                # Test database connectivity with timeout
                if timeout "$MYSQL_TIMEOUT" docker exec "$users_container" mysql -u root -p"$users_password" -e "SELECT 1;" >/dev/null 2>&1; then
                    log DEBUG "Users database connection verified"

                    # Create database dump (all databases)
                    local dump_base="$snapshot_dir/databases/panelalpha-users.sql"
                    local dump_file="$dump_base"
                    local users_dump_compressed=false

                    if command -v gzip &> /dev/null; then
                        dump_file="${dump_base}.gz"
                        users_dump_compressed=true
                    fi

                    local -a mysqldump_args=(
                        mysqldump
                        -u root
                        --all-databases
                        --single-transaction
                        --routines
                        --triggers
                        --lock-tables=false
                        --add-drop-database
                        --create-options
                        --disable-keys
                        --extended-insert
                        --quick
                        --set-charset
                        --tz-utc
                        --hex-blob
                        --max-allowed-packet=512M
                    )

                    local dump_success=false
                    log INFO "Creating Users databases dump (this may take a while)..."
                    
                    if [[ "$users_dump_compressed" == true ]]; then
                        # Start compressed dump in background
                        timeout "$USERS_DUMP_TIMEOUT" docker exec -e MYSQL_PWD="$users_password" "$users_container" \
                            sh -c "${mysqldump_args[*]} 2>/dev/null | gzip -c -${USERS_DUMP_COMPRESSION_LEVEL}" \
                            > "$dump_file" 2>/dev/null &
                        local dump_pid=$!
                        
                        # Monitor progress
                        monitor_dump_progress "$dump_file" "Users databases dump (compressed)" "$USERS_DUMP_TIMEOUT" &
                        local monitor_pid=$!
                        
                        if wait $dump_pid; then
                            kill $monitor_pid 2>/dev/null || true
                            wait $monitor_pid 2>/dev/null || true
                            dump_success=true
                        else
                            kill $monitor_pid 2>/dev/null || true
                            wait $monitor_pid 2>/dev/null || true
                            log WARN "User database compression failed - retrying without compression"
                            rm -f "$dump_file" 2>/dev/null || true
                            users_dump_compressed=false
                            dump_file="$dump_base"
                        fi
                    fi

                    if [[ "$users_dump_compressed" == false && "$dump_success" == false ]]; then
                        # Start uncompressed dump in background
                        timeout "$USERS_DUMP_TIMEOUT" docker exec -e MYSQL_PWD="$users_password" "$users_container" \
                            "${mysqldump_args[@]}" \
                            > "$dump_file" 2>/dev/null &
                        local dump_pid=$!
                        
                        # Monitor progress
                        monitor_dump_progress "$dump_file" "Users databases dump" "$USERS_DUMP_TIMEOUT" &
                        local monitor_pid=$!
                        
                        if wait $dump_pid; then
                            kill $monitor_pid 2>/dev/null || true
                            wait $monitor_pid 2>/dev/null || true
                            dump_success=true
                        else
                            kill $monitor_pid 2>/dev/null || true
                            wait $monitor_pid 2>/dev/null || true
                        fi
                    fi

                    if [[ "$dump_success" == true ]]; then
                        # Verify snapshot file integrity
                        if verify_file_integrity "$dump_file" 1000; then
                            local users_size
                            users_size=$(stat -c%s "$dump_file" 2>/dev/null || echo "0")
                            if [[ "$users_dump_compressed" == true ]]; then
                                log INFO "✓ Users databases snapshot created ($(( users_size / 1024 )) KB compressed)"
                            else
                                log INFO "✓ Users databases snapshot created ($(( users_size / 1024 )) KB)"
                            fi
                        else
                            log ERROR "✗ Users databases snapshot is corrupted"
                            snapshot_success=false
                        fi
                    else
                        log ERROR "✗ Users databases snapshot failed"
                        snapshot_success=false
                    fi
                else
                    log ERROR "✗ Cannot connect to Users database"
                    log ERROR "Check database password in $ENV_FILE file"
                    snapshot_success=false
                fi
            fi
        else
            log WARN "USERS_MYSQL_ROOT_PASSWORD not found - skipping Users databases"
        fi
        
    else
        # Original Control Panel logic
        log INFO "Detected PanelAlpha Control Panel - backing up API database"
        
        # Extract database passwords from environment file securely
        local api_password
        api_password=$(grep "^API_MYSQL_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | head -1 || echo "")

        local total_steps=1
        local current_step=0

        # Snapshot PanelAlpha database
        if [[ -n "$api_password" ]]; then
            ((current_step++))
            show_progress $current_step $total_steps "Creating PanelAlpha database snapshot"
            
            local api_container
            api_container=$(docker compose ps -q database-api 2>/dev/null)

            if [[ -z "$api_container" ]]; then
                log ERROR "API database container not found"
                snapshot_success=false
            else
                # Test database connectivity with timeout
                if timeout "$MYSQL_TIMEOUT" docker exec "$api_container" mysql -u panelalpha -p"$api_password" -e "SELECT 1;" >/dev/null 2>&1; then
                    log DEBUG "API database connection verified"

                    # Create database dump with enhanced options and error checking
                    local dump_file="$snapshot_dir/databases/panelalpha-api.sql"
                    if timeout 300 docker exec "$api_container" \
                        mysqldump -u panelalpha -p"$api_password" panelalpha \
                        --single-transaction --routines --triggers --lock-tables=false \
                        --add-drop-database --create-options --disable-keys \
                        --extended-insert --quick --set-charset \
                        > "$dump_file" 2>/dev/null; then

                        # Verify snapshot file integrity
                        if verify_file_integrity "$dump_file" 1000; then
                            local api_size
                            api_size=$(stat -c%s "$dump_file" 2>/dev/null || echo "0")
                            log INFO "✓ PanelAlpha database snapshot created ($(( api_size / 1024 )) KB)"
                        else
                            log ERROR "✗ PanelAlpha database snapshot is corrupted"
                            snapshot_success=false
                        fi
                    else
                        log ERROR "✗ PanelAlpha database snapshot failed"
                        snapshot_success=false
                    fi
                else
                    log ERROR "✗ Cannot connect to PanelAlpha database"
                    log ERROR "Check database password in $ENV_FILE file"
                    snapshot_success=false
                fi
            fi
        else
            log WARN "API_MYSQL_PASSWORD not found - skipping PanelAlpha database"
        fi
    fi

    # Final verification and summary
    if [[ "$snapshot_success" == true ]]; then
        local total_size
        total_size=$(du -sh "$snapshot_dir/databases" 2>/dev/null | cut -f1 || echo "0")
        log INFO "Database snapshots completed - size: $total_size"

        # Log database verification info
        # log DEBUG "Database snapshot verification:"
        # if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
        #     if [[ -f "$snapshot_dir/databases/panelalpha-core.sql" ]]; then
        #         local core_lines
        #         core_lines=$(wc -l < "$snapshot_dir/databases/panelalpha-core.sql" 2>/dev/null || echo "0")
        #         log DEBUG "  Core: $core_lines lines"
        #     fi
        #     if [[ -f "$snapshot_dir/databases/panelalpha-users.sql.gz" ]]; then
        #         local users_lines
        #         users_lines=$(gzip -cd "$snapshot_dir/databases/panelalpha-users.sql.gz" 2>/dev/null | wc -l 2>/dev/null || echo "0")
        #         log DEBUG "  Users: $users_lines lines (compressed)"
        #     elif [[ -f "$snapshot_dir/databases/panelalpha-users.sql" ]]; then
        #         local users_lines
        #         users_lines=$(wc -l < "$snapshot_dir/databases/panelalpha-users.sql" 2>/dev/null || echo "0")
        #         log DEBUG "  Users: $users_lines lines"
        #     fi
        # else
        #     if [[ -f "$snapshot_dir/databases/panelalpha-api.sql" ]]; then
        #         local api_lines
        #         api_lines=$(wc -l < "$snapshot_dir/databases/panelalpha-api.sql" 2>/dev/null || echo "0")
        #         log DEBUG "  PanelAlpha: $api_lines lines"
        #     fi
        # fi
        
        return 0
    else
        log ERROR "Database snapshots completed with errors"
        return 1
    fi
}

# Create Docker volumes snapshot
create_volumes_snapshot() {
    log INFO "Creating Docker volumes snapshot..."

    local snapshot_dir="$1"
    mkdir -p "$snapshot_dir/volumes"

    cd "$PANELALPHA_DIR"

    # Define critical volumes based on application type
    local volumes=()
    if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
        log INFO "Using Engine volume configuration"
        volumes=(
            "core-storage"
            "database-core-data"
            "database-users-data"
        )
    else
        log INFO "Using Control Panel volume configuration"
        volumes=(
            "api-storage"
            "database-api-data"
            "redis-data"
        )
    fi

    local volumes_processed=0
    local volumes_total=${#volumes[@]}

    for volume in "${volumes[@]}"; do
        local full_volume_name="${PWD##*/}_$volume"
        
        if docker volume inspect "$full_volume_name" &> /dev/null; then
            log INFO "Creating snapshot of volume: $volume"
            
            # Get volume size for reference
            local vol_size
            vol_size=$(docker system df -v 2>/dev/null | grep "$full_volume_name" | awk '{print $3}' || echo "unknown")
            if [[ -n "$vol_size" && "$vol_size" != "unknown" ]]; then
                log DEBUG "Volume size: $vol_size"
            fi
            
            # Create volume snapshot using temporary container with better error handling
            local tar_output
            tar_output=$(mktemp)
            local tar_file="$snapshot_dir/volumes/$volume.tar.gz"
            
            # Use tar with options to handle database files that may change during backup
            # Run in background to monitor progress
            docker run --rm \
                -v "$full_volume_name":/source:ro \
                -v "$snapshot_dir/volumes":/target \
                ubuntu:20.04 \
                tar czf "/target/$volume.tar.gz" \
                --warning=no-file-changed \
                --ignore-failed-read \
                -C /source . 2>"$tar_output" &
            local tar_pid=$!
            
            # Monitor progress while tar is running
            monitor_dump_progress "$tar_file" "Volume $volume snapshot" "$VOLUME_SNAPSHOT_TIMEOUT" &
            local monitor_pid=$!
            
            # Wait for tar to complete
            wait $tar_pid
            local tar_exit_code=$?
            
            # Stop monitor
            kill $monitor_pid 2>/dev/null || true
            wait $monitor_pid 2>/dev/null || true
            
            # Check if tar file was created and has content
            local tar_file_exists=false
            local snap_size=0
            if [[ -f "$tar_file" ]]; then
                snap_size=$(stat -c%s "$tar_file" 2>/dev/null || echo "0")
                if [[ $snap_size -gt 1000 ]]; then
                    tar_file_exists=true
                fi
            fi
            
            # Evaluate success based on file creation, not exit code
            # tar exit code 1 means "some files changed during archive creation" - this is OK for database volumes
            if [[ "$tar_file_exists" == true ]]; then
                ((volumes_processed++))
                log INFO "✓ Volume $volume snapshot created ($(( snap_size / 1024 )) KB)"
            else
                local error_msg
                error_msg=$(cat "$tar_output" 2>/dev/null || echo "unknown error")
                
                if [[ -f "$tar_file" ]]; then
                    # File exists but is too small
                    log WARN "✗ Volume $volume snapshot file is too small (${snap_size} bytes)"
                    rm -f "$tar_file"
                else
                    # File was not created at all
                    log WARN "✗ Failed to create snapshot for volume: $volume"
                    if [[ -n "$error_msg" ]]; then
                        log DEBUG "Error details: $error_msg"
                    fi
                fi
            fi
            
            rm -f "$tar_output" 2>/dev/null || true
        else
            log WARN "Volume $full_volume_name not found - skipping"
        fi
    done

    local total_size
    total_size=$(du -sh "$snapshot_dir/volumes" 2>/dev/null | cut -f1 || echo "0")
    log INFO "Volumes snapshot completed: $volumes_processed/$volumes_total volumes ($total_size)"

    return 0
}

# Create configuration files snapshot
create_config_snapshot() {
    log INFO "Creating configuration snapshot..."

    local snapshot_dir="$1"
    mkdir -p "$snapshot_dir/config"

    cd "$PANELALPHA_DIR"

    # Snapshot packages directory with exclusions for performance
    if [[ -d "packages/" ]]; then
        log INFO "Creating packages directory snapshot..."
        
        if command -v rsync &> /dev/null; then
            # Use rsync for efficient copying with exclusions
            if rsync -av \
                --exclude='.git/' \
                --exclude='node_modules/' \
                --exclude='vendor/' \
                --exclude='cache/' \
                --exclude='*.log' \
                --exclude='tmp/' \
                --exclude='.DS_Store' \
                "packages/" "$snapshot_dir/config/packages/" 2>/dev/null; then
                log INFO "✓ Packages directory snapshot created"
            else
                log WARN "✗ Failed to create packages directory snapshot"
            fi
        else
            # Fallback to cp if rsync is not available
            if cp -r packages/ "$snapshot_dir/config/" 2>/dev/null; then
                log INFO "✓ Packages directory snapshot created (using cp)"
            else
                log WARN "✗ Failed to create packages directory snapshot"
            fi
        fi
    else
        log INFO "No packages directory found - skipping"
    fi

    # Snapshot core configuration files
    local config_files=(
        "docker-compose.yml"
        "nginx.conf"
        "Dockerfile"
    )
    
    # Always include the active environment file
    config_files+=("$ENV_FILE_NAME")

    # Snapshot pasnap configuration file
    if [[ -f "$CONFIG_FILE" ]]; then
        if cp "$CONFIG_FILE" "$snapshot_dir/config/.env-backup" 2>/dev/null; then
            log DEBUG "✓ .env-backup snapshot created"
        else
            log WARN "✗ Failed to snapshot .env-backup"
        fi
    fi

    for file in "${config_files[@]}"; do
        if [[ -f "$file" ]]; then
            if cp "$file" "$snapshot_dir/config/" 2>/dev/null; then
                log DEBUG "✓ $file snapshot created"
            else
                log WARN "✗ Failed to snapshot $file"
            fi
        else
            log DEBUG "$file not found - skipping"
        fi
    done

    # Snapshot SSL certificates if present
    if [[ -d "/etc/letsencrypt" ]]; then
        log INFO "Creating SSL certificates snapshot..."
        mkdir -p "$snapshot_dir/config/ssl"
        
        if cp -r /etc/letsencrypt/ "$snapshot_dir/config/ssl/" 2>/dev/null; then
            log INFO "✓ SSL certificates snapshot created"
        else
            log WARN "✗ Failed to create SSL certificates snapshot"
        fi
    else
        log INFO "No SSL certificates found - skipping"
    fi

    local config_size
    config_size=$(du -sh "$snapshot_dir/config" 2>/dev/null | cut -f1 || echo "0")
    log INFO "Configuration snapshot size: $config_size"

    return 0
}

create_users_snapshot() {
    local snapshot_dir="$1"

    if [[ "$PANELALPHA_APP_TYPE" != "engine" ]]; then
        log DEBUG "Skipping user container snapshot for application type: $PANELALPHA_APP_TYPE"
        return 0
    fi

    local users_source="${PANELALPHA_DIR}/users"
    if [[ ! -d "$users_source" ]]; then
        log INFO "No user container directory found at $users_source - skipping"
        return 0
    fi

    local target_dir="$snapshot_dir/users"
    mkdir -p "$target_dir"

    log INFO "Creating user containers snapshot from $users_source..."
    local users_snapshot_success=false
    local rsync_exit_code=0

    if command -v rsync &> /dev/null; then
        # rsync may return non-zero exit code for various reasons, but snapshot may still be created
        # Use timeout to prevent hanging on large directories
        timeout "$USERS_HOME_SNAPSHOT_TIMEOUT" rsync -a "$users_source/" "$target_dir/" 2>/dev/null || rsync_exit_code=$?
        
        if [[ -d "$target_dir" ]] && [[ -n "$(find "$target_dir" -type f 2>/dev/null | head -1)" ]]; then
            log INFO "✓ User container projects snapshot created"
            users_snapshot_success=true
        else
            if [[ $rsync_exit_code -ne 0 ]]; then
                log DEBUG "rsync exit code: $rsync_exit_code - will try fallback"
            fi
        fi
    fi

    # Fallback to cp if rsync failed or is not available
    if [[ $users_snapshot_success == false ]]; then
        if cp -a "$users_source/." "$target_dir/" 2>/dev/null; then
            log INFO "✓ User container projects snapshot created (using cp fallback)"
            users_snapshot_success=true
        else
            log ERROR "✗ Failed to snapshot user container projects"
        fi
    fi

    local compose_status_file="$target_dir/container-status.txt"
    : > "$compose_status_file"
    local -a compose_files=()
    mapfile -t compose_files < <(find "$users_source" -maxdepth 2 -type f -name "docker-compose.yml" 2>/dev/null || true)
    if (( ${#compose_files[@]} > 0 )); then
        for compose_file in "${compose_files[@]}"; do
            local user_dir
            user_dir=$(dirname "$compose_file")
            local user_name
            user_name=$(basename "$user_dir")
            {
                echo "[$user_name]"
                docker compose -f "$compose_file" ps 2>/dev/null || echo "Unable to query container state"
                echo
            } >> "$compose_status_file"
        done
        log DEBUG "User container status saved to $compose_status_file"
    else
        rm -f "$compose_status_file"
        log DEBUG "No user docker-compose.yml files detected"
    fi

    local users_size
    users_size=$(du -sh "$target_dir" 2>/dev/null | cut -f1 || echo "0")
    log INFO "User containers snapshot size: $users_size"

    if [[ "$users_snapshot_success" == true ]]; then
        return 0
    fi

    return 1
}

create_home_snapshot() {
    local snapshot_dir="$1"

    if [[ "$PANELALPHA_APP_TYPE" != "engine" ]]; then
        log DEBUG "Skipping /home snapshot for application type: $PANELALPHA_APP_TYPE"
        return 0
    fi

    local home_dir="/home"
    if [[ ! -d "$home_dir" ]]; then
        log WARN "/home directory not found - skipping snapshot"
        return 0
    fi

    local target_dir="$snapshot_dir/home"
    mkdir -p "$target_dir"

    log INFO "Creating /home directory snapshot (this may take a while)..."
    local home_snapshot_success=false
    local rsync_exit_code=0
    local rsync_has_files=false

    if command -v rsync &> /dev/null; then
        # rsync may return exit code 23 if some files couldn't be read (normal for /home with various permissions)
        # Use timeout to prevent hanging on large directories
        timeout "$USERS_HOME_SNAPSHOT_TIMEOUT" rsync -a --numeric-ids "$home_dir/" "$target_dir/" 2>/dev/null || rsync_exit_code=$?

        if [[ -d "$target_dir" ]] && [[ -n "$(find "$target_dir" -type f 2>/dev/null | head -1)" ]]; then
            rsync_has_files=true
        fi

        if [[ $rsync_exit_code -eq 0 ]]; then
            if [[ $rsync_has_files == true ]]; then
                log INFO "✓ /home snapshot created"
            else
                log WARN "rsync transferred no files - /home may be empty"
            fi
            home_snapshot_success=true
        elif [[ $rsync_has_files == true ]]; then
            case $rsync_exit_code in
                23|24)
                    log WARN "rsync completed with partial errors (exit code $rsync_exit_code) - snapshot may be incomplete"
                    ;;
                12)
                    log WARN "rsync exited with out-of-memory (exit code $rsync_exit_code) - snapshot may be incomplete"
                    ;;
                30)
                    log WARN "rsync exited due to timeout in data send/receive (exit code $rsync_exit_code) - snapshot may be incomplete"
                    ;;
                124|137)
                    log WARN "rsync timed out (exit code $rsync_exit_code) - snapshot may be incomplete"
                    ;;
                *)
                    log WARN "rsync exited with code $rsync_exit_code - snapshot may be incomplete"
                    ;;
            esac
            home_snapshot_success=true
        else
            log DEBUG "rsync exit code: $rsync_exit_code"
            if [[ $rsync_exit_code -eq 12 ]]; then
                log ERROR "✗ rsync error: out of memory"
            elif [[ $rsync_exit_code -eq 30 ]]; then
                log ERROR "✗ rsync error: timeout in data send/receive"
            elif [[ $rsync_exit_code -eq 124 || $rsync_exit_code -eq 137 ]]; then
                log ERROR "✗ rsync error: timeout reached"
            else
                log WARN "rsync failed (exit code $rsync_exit_code) - attempting fallback with cp"
            fi
        fi
    fi

    # Fallback to cp if rsync is not available or had issues
    if [[ $home_snapshot_success == false ]]; then
        if cp -a "$home_dir/." "$target_dir/" 2>/dev/null; then
            log INFO "✓ /home snapshot created (using cp fallback)"
            home_snapshot_success=true
        else
            if [[ -n "$(find "$target_dir" -type f 2>/dev/null | head -1)" ]]; then
                log WARN "cp fallback failed, but /home snapshot contains data"
                home_snapshot_success=true
            else
                log ERROR "✗ Failed to snapshot /home directory (both rsync and cp failed)"
            fi
        fi
    fi

    local home_size
    home_size=$(du -sh "$target_dir" 2>/dev/null | cut -f1 || echo "0")
    log INFO "/home snapshot size: $home_size"

    if [[ "$home_snapshot_success" == true ]]; then
        return 0
    fi

    return 1
}

# Main snapshot creation function with enhanced error handling
create_snapshot() {
    log INFO "=== Creating PanelAlpha Snapshot ==="

    check_requirements

    # Create temporary directory for snapshot with random suffix for security
    local random_suffix
    random_suffix=$(openssl rand -hex 4 2>/dev/null || date +%s)
    BACKUP_TEMP_DIR="${BACKUP_TEMP_DIR}-${random_suffix}"
    
    if ! mkdir -p "$BACKUP_TEMP_DIR"; then
        log ERROR "Cannot create temporary directory: $BACKUP_TEMP_DIR"
        exit 1
    fi
    
    # Set secure permissions
    chmod 700 "$BACKUP_TEMP_DIR"
    
    # Set up cleanup trap with error handling
    trap 'cleanup_temp_dir' EXIT ERR

    log INFO "Using temporary directory: $BACKUP_TEMP_DIR"

    # Create all snapshot components with progress tracking
    log INFO "Creating snapshot components..."
    
    local start_time
    start_time=$(date +%s)
    
    if ! create_database_snapshot "$BACKUP_TEMP_DIR"; then
        log ERROR "Database snapshot failed"
        exit 1
    fi

    if ! create_volumes_snapshot "$BACKUP_TEMP_DIR"; then
        log ERROR "Volume snapshot failed"
        exit 1
    fi

    if ! create_config_snapshot "$BACKUP_TEMP_DIR"; then
        log ERROR "Configuration snapshot failed"
        exit 1
    fi

    if ! create_users_snapshot "$BACKUP_TEMP_DIR"; then
        log ERROR "User container snapshot failed"
        exit 1
    fi

    if ! create_home_snapshot "$BACKUP_TEMP_DIR"; then
        log ERROR "/home snapshot failed"
        exit 1
    fi

    # Calculate total snapshot size and performance metrics
    local total_size
    total_size=$(du -sh "$BACKUP_TEMP_DIR" 2>/dev/null | cut -f1 || echo "unknown")
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log INFO "Total snapshot size: $total_size"
    log INFO "Local snapshot creation time: ${duration}s"

    # Create snapshot metadata
    create_snapshot_metadata "$BACKUP_TEMP_DIR" "$total_size" "$duration"

    # Initialize repository if needed (with retry)
    local retry_count=0
    while [[ $retry_count -lt $MAX_RETRY_ATTEMPTS ]]; do
        if restic init --repo "$RESTIC_REPOSITORY" 2>/dev/null; then
            log DEBUG "Repository initialized"
            break
        elif restic snapshots --repo "$RESTIC_REPOSITORY" --last 1 >/dev/null 2>&1; then
            log DEBUG "Repository already exists"
            break
        else
            ((retry_count++))
            if [[ $retry_count -lt $MAX_RETRY_ATTEMPTS ]]; then
                log WARN "Repository initialization failed, retrying ($retry_count/$MAX_RETRY_ATTEMPTS)"
                sleep 5
            else
                log ERROR "Cannot initialize repository after $MAX_RETRY_ATTEMPTS attempts"
                exit 1
            fi
        fi
    done

    # Create snapshot in repository with progress tracking
    log INFO "Uploading snapshot to repository..."
    local upload_start
    upload_start=$(date +%s)
    
    local restic_tags=(--tag "$BACKUP_TAG" --tag "databases" --tag "volumes" --tag "config")
    if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
        restic_tags+=(--tag "users" --tag "home")
    fi

    local snapshot_result
    snapshot_result=$(restic backup "$BACKUP_TEMP_DIR" \
        --repo "$RESTIC_REPOSITORY" \
        "${restic_tags[@]}" \
        --verbose \
        --json 2>/dev/null) || {
        log ERROR "Failed to create snapshot in repository"
        log ERROR "Check network connection and repository settings"
        exit 1
    }

    local upload_end
    upload_end=$(date +%s)
    local upload_duration=$((upload_end - upload_start))

    # Extract and display snapshot ID with error checking
    local snapshot_id=""
    if [[ -n "$snapshot_result" ]]; then
        snapshot_id=$(echo "$snapshot_result" | jq -r 'select(.snapshot_id != null) | .snapshot_id' 2>/dev/null | tail -n 1 || echo "")
    fi

    if [[ -n "$snapshot_id" && "$snapshot_id" != "null" ]]; then
        log INFO "✓ Snapshot created successfully: $snapshot_id"
        log INFO "Upload time: ${upload_duration}s"
    else
        log WARN "Snapshot created, but cannot determine ID"
    fi

    # Clean up old snapshots according to retention policy
    log INFO "Applying retention policy (keeping $BACKUP_RETENTION_DAYS days)..."
    if restic forget \
        --repo "$RESTIC_REPOSITORY" \
        --tag "$BACKUP_TAG" \
        --keep-daily "$BACKUP_RETENTION_DAYS" \
        --prune 2>/dev/null; then
        log INFO "✓ Old snapshots have been removed"
    else
        log WARN "Failed to remove old snapshots"
    fi

    # Final verification
    local final_verification
    final_verification=$(restic snapshots --repo "$RESTIC_REPOSITORY" --tag "$BACKUP_TAG" --json 2>/dev/null | jq length 2>/dev/null || echo "0")
    log INFO "Number of snapshots in repository: $final_verification"

    log INFO "=== Snapshot creation completed successfully ✓ ==="
    
    if [[ -n "$snapshot_id" && "$snapshot_id" != "null" ]]; then
        echo
        echo "🎉 SUCCESS!"
        echo "Snapshot ID: $snapshot_id"
        echo "Size: $total_size"
        echo "Time: ${duration}s (local) + ${upload_duration}s (upload)"
        echo
        echo "To restore this snapshot:"
        echo "sudo $0 --restore $snapshot_id"
    fi
}

# Enhanced cleanup function
cleanup_temp_dir() {
    if [[ -n "${BACKUP_TEMP_DIR:-}" && -d "$BACKUP_TEMP_DIR" ]]; then
        log DEBUG "Cleaning temporary directory: $BACKUP_TEMP_DIR"
        rm -rf "$BACKUP_TEMP_DIR" 2>/dev/null || {
            log WARN "Cannot remove temporary directory: $BACKUP_TEMP_DIR"
        }
    fi
}

# Create snapshot metadata file with enhanced information
create_snapshot_metadata() {
    local snapshot_dir="$1"
    local total_size="$2"
    local duration="${3:-unknown}"
    
    local server_info
    server_info=$(cat << EOF
$(lsb_release -d 2>/dev/null | cut -f2 || echo "Unknown Linux")
Kernel: $(uname -r)
Architecture: $(uname -m)
Docker: $(docker --version 2>/dev/null || echo "Unknown")
EOF
)
    
    cat > "$snapshot_dir/snapshot-info.txt" << EOF
PanelAlpha Snapshot Information
========================================
Created: $(date)
Hostname: $(hostname)
Server IP: $(hostname -I | awk '{print $1}' 2>/dev/null || echo "unknown")
Script Version: $SCRIPT_VERSION
Configuration: $CONFIG_FILE
Total Size: $total_size
Creation Time: ${duration}s
Repository: $RESTIC_REPOSITORY
Tag: $BACKUP_TAG

System Information:
$server_info
Application Type: $PANELALPHA_APP_TYPE

Components Included:
$(if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
    echo "- Databases (Core, Users)"
    echo "- Docker volumes (core-storage, database-core-data, database-users-data)"
    echo "- Configuration files (docker-compose.yml, $ENV_FILE_NAME, packages/, SSL certificates)"
    echo "- User container projects (${PANELALPHA_DIR}/users)"
    echo "- User home directories (/home)"
else
    echo "- Databases (PanelAlpha API)"
    echo "- Docker volumes (api-storage, database-api-data, redis-data)"
    echo "- Configuration files (docker-compose.yml, $ENV_FILE_NAME, packages/, SSL certificates)"
fi)

Verification:
- Database dumps verified for minimum size
- File integrity checked
- Docker volumes archived with compression

Recovery Instructions:
1. Install PanelAlpha on target server
2. Copy this snapshot tool to target server
3. Configure snapshot repository (same settings)
4. Run: sudo ./pasnap.sh --restore <snapshot-id>

For detailed recovery instructions, see the README.md file.

Security:
- All data encrypted with AES-256
- Repository password protected
- Temporary files securely removed
- Network connections use TLS/SSL

EOF
}

# ======================
# SNAPSHOT MANAGEMENT FUNCTIONS
# ======================

list_snapshots() {
    log INFO "=== Available Snapshots ==="

    check_requirements

    log INFO "Snapshots in repository:"
    echo

    # List all snapshots with detailed info
    restic snapshots --repo "$RESTIC_REPOSITORY" --compact --tag "$BACKUP_TAG" 2>/dev/null || {
        log WARN "No snapshots found with tag '$BACKUP_TAG'"
        log INFO "Listing all snapshots:"
        restic snapshots --repo "$RESTIC_REPOSITORY" --compact 2>/dev/null || {
            log ERROR "Failed to list snapshots or repository is empty"
            return 1
        }
    }
    echo
}

delete_snapshot() {
    local snapshot_id="$1"

    if [[ -z "$snapshot_id" ]]; then
        log ERROR "Snapshot ID is required"
        log ERROR "Usage: $0 --delete-snapshots <snapshot_id>"
        exit 1
    fi

    log INFO "=== Deleting Snapshot: $snapshot_id ==="

    check_requirements

    # Check if snapshot exists
    if ! restic snapshots --repo "$RESTIC_REPOSITORY" --json | jq -r '.[].short_id' | grep -q "^${snapshot_id}$" 2>/dev/null; then
        log ERROR "Snapshot $snapshot_id does not exist"
        log INFO "Available snapshots:"
        restic snapshots --repo "$RESTIC_REPOSITORY" --compact 2>/dev/null || true
        exit 1
    fi

    # Show snapshot info before deletion
    log INFO "Snapshot to delete:"
    restic snapshots --repo "$RESTIC_REPOSITORY" "$snapshot_id" 2>/dev/null || true
    echo

    # Confirm deletion
    read -p "Are you sure you want to delete snapshot $snapshot_id? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log INFO "Deletion cancelled"
        return 0
    fi

    # Delete snapshot
    log INFO "Deleting snapshot $snapshot_id..."
    if restic forget --repo "$RESTIC_REPOSITORY" "$snapshot_id" --prune; then
        log INFO "✓ Snapshot $snapshot_id deleted successfully"
    else
        log ERROR "✗ Failed to delete snapshot $snapshot_id"
        exit 1
    fi
}

# ======================
# RESTORE FUNCTIONS
# ======================

resolve_snapshot() {
    local input="$1"

    if [[ "$input" == "latest" ]]; then
        # Try current server tag first
        SNAPSHOT_ID=$(restic snapshots --repo "$RESTIC_REPOSITORY" --tag "$BACKUP_TAG" \
            --json 2>/dev/null | jq -r 'if length > 0 then .[0].short_id else empty end' 2>/dev/null || echo "")

        # If not found, try any panelalpha tag
        if [[ -z "$SNAPSHOT_ID" || "$SNAPSHOT_ID" == "null" ]]; then
            SNAPSHOT_ID=$(restic snapshots --repo "$RESTIC_REPOSITORY" --tag "panelalpha" \
                --json 2>/dev/null | jq -r 'if length > 0 then .[0].short_id else empty end' 2>/dev/null || echo "")
        fi

        # If still not found, try latest snapshot overall
        if [[ -z "$SNAPSHOT_ID" || "$SNAPSHOT_ID" == "null" ]]; then
            SNAPSHOT_ID=$(restic snapshots --repo "$RESTIC_REPOSITORY" \
                --json 2>/dev/null | jq -r 'if length > 0 then .[0].short_id else empty end' 2>/dev/null || echo "")
        fi

        # Final check - if still null or empty, no snapshots exist
        if [[ -z "$SNAPSHOT_ID" || "$SNAPSHOT_ID" == "null" ]]; then
            log ERROR "Cannot find any snapshots in repository"
            log ERROR "Please create a snapshot first with: $0 --snapshot"
            exit 1
        fi
        log INFO "Latest snapshot: $SNAPSHOT_ID"
    else
        SNAPSHOT_ID="$input"
    fi

    # Check if snapshot exists (skip for null/empty)
    if [[ -n "$SNAPSHOT_ID" && "$SNAPSHOT_ID" != "null" ]]; then
        if ! restic snapshots --repo "$RESTIC_REPOSITORY" --json | jq -r '.[].short_id' | grep -q "^${SNAPSHOT_ID}$" 2>/dev/null; then
            log ERROR "Snapshot $SNAPSHOT_ID does not exist"
            log INFO "Available snapshots:"
            restic snapshots --repo "$RESTIC_REPOSITORY" --compact 2>/dev/null || log ERROR "Could not list snapshots"
            exit 1
        fi
    else
        log ERROR "Invalid snapshot ID: $SNAPSHOT_ID"
        exit 1
    fi
}

restore_snapshot() {
    local snapshot_id="$1"
    local target_dir="$2"

    log INFO "Restoring snapshot $snapshot_id..."
    mkdir -p "$target_dir"

    restic restore "$snapshot_id" --repo "$RESTIC_REPOSITORY" --target "$target_dir"
}

wait_for_database_containers_enhanced() {
    log INFO "Waiting for database containers to be ready..."

    local container1 container2 name1 name2
    
    if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
        container1=$(docker compose ps -q database-core)
        container2=$(docker compose ps -q database-users)
        name1="Core"
        name2="Users"
        
        if [[ -z "$container1" || -z "$container2" ]]; then
            log ERROR "One or both database containers are not running"
            return 1
        fi
    else
        container1=$(docker compose ps -q database-api)
        name1="API"
        
        if [[ -z "$container1" ]]; then
            log ERROR "Database container is not running"
            return 1
        fi
        
        # For Control Panel, only check one container
        container2=""
        name2=""
    fi

    local max_attempts=120
    local attempt=0

    log INFO "Checking if MySQL/MariaDB processes are running and ready to accept connections..."

    while [[ $attempt -lt $max_attempts ]]; do
        local db1_ready=false
        local db2_ready=true  # Default to true for Control Panel (single container)

        # Check first database - just basic MySQL connectivity without authentication
        if docker exec "$container1" mysqladmin ping --silent 2>/dev/null; then
            log DEBUG "$name1 database is responding to ping"
            db1_ready=true
        else
            log DEBUG "$name1 database not ready yet"
        fi

        # Check second database only if it exists (Engine only)
        if [[ -n "$container2" ]]; then
            db2_ready=false
            if docker exec "$container2" mysqladmin ping --silent 2>/dev/null; then
                log DEBUG "$name2 database is responding to ping"
                db2_ready=true
            else
                log DEBUG "$name2 database not ready yet"
            fi
        fi

        if [[ "$db1_ready" == "true" && "$db2_ready" == "true" ]]; then
            if [[ -n "$container2" ]]; then
                log INFO "Both database containers are ready"
            else
                log INFO "Database container is ready"
            fi
            return 0
        fi

        ((attempt++))
        if [[ $((attempt % 10)) -eq 0 ]]; then
            log INFO "Still waiting for databases... (attempt $attempt/$max_attempts)"
        fi
        sleep 2
    done

    log ERROR "Timeout waiting for database containers to be ready"

    # Debug information
    log ERROR "Debug information:"
    log ERROR "$name1 container logs:"
    docker logs "$container1" --tail 10 2>/dev/null || true
    if [[ -n "$container2" ]]; then
        log ERROR "$name2 container logs:"
        docker logs "$container2" --tail 10 2>/dev/null || true
    fi

    return 1
}

clean_database_volumes() {
    log INFO "Cleaning database volumes..."

    cd "$PANELALPHA_DIR"

    # Get volume names based on application type
    local volume1 volume2
    if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
        volume1="${PWD##*/}_database-core-data"
        volume2="${PWD##*/}_database-users-data"
    else
        volume1="${PWD##*/}_database-api-data"
        volume2=""  # No second database for Control Panel
    fi

    # Remove first database volume
    if docker volume inspect "$volume1" &> /dev/null; then
        log INFO "Removing database volume: $volume1"
        docker volume rm "$volume1" 2>/dev/null || log WARN "Could not remove volume (may not exist)"
    fi

    # Remove second database volume (Engine only)
    if [[ -n "$volume2" ]] && docker volume inspect "$volume2" &> /dev/null; then
        log INFO "Removing database volume: $volume2"
        docker volume rm "$volume2" 2>/dev/null || log WARN "Could not remove volume (may not exist)"
    fi

    log INFO "Database volumes cleaned"
}

get_mysql_root_password() {
    local container="$1"

    # Try to get root password from container environment variables
    local root_password=""

    # Check common environment variable names for root password
    root_password=$(docker exec "$container" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")
    if [[ -z "$root_password" ]]; then
        root_password=$(docker exec "$container" printenv MARIADB_ROOT_PASSWORD 2>/dev/null || echo "")
    fi

    # If still empty, check the ENV_FILE for database passwords
    if [[ -z "$root_password" ]]; then
        root_password=$(grep "^DATABASE_ROOT_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
    fi

    echo "$root_password"
}

setup_database_user() {
    local container="$1"
    local username="$2"
    local password="$3"

    log INFO "Setting up database user: $username"

    # First, wait a bit for MySQL to be fully ready
    sleep 5

    # For fresh containers, MySQL usually allows root access without password initially
    # But we should avoid using root and instead check if user already exists
    log INFO "Checking if user $username already exists..."

    # Try to login with the user credentials first
    if docker exec "$container" mysql -u "$username" -p"$password" -e "SELECT 1;" 2>/dev/null >/dev/null; then
        log INFO "✓ User $username already exists and can login successfully"
        return 0
    fi

    # If user doesn't exist, we need to create it
    # Try different approaches to create the user
    log INFO "User $username doesn't exist, attempting to create..."

    # Try with root without password (fresh container)
    if docker exec "$container" mysql -e "
        CREATE USER IF NOT EXISTS '$username'@'%' IDENTIFIED BY '$password';
        CREATE USER IF NOT EXISTS '$username'@'localhost' IDENTIFIED BY '$password';
        GRANT ALL PRIVILEGES ON $username.* TO '$username'@'%';
        GRANT ALL PRIVILEGES ON $username.* TO '$username'@'localhost';
        FLUSH PRIVILEGES;
    " 2>/dev/null; then
        log INFO "✓ User $username created successfully using root without password"
    else
        # Try with mysql root password from environment variables if available
        local mysql_root_password=$(get_mysql_root_password "$container")

        if [[ -n "$mysql_root_password" ]]; then
            log INFO "Trying with root password from environment..."
            if docker exec "$container" mysql -u root -p"$mysql_root_password" -e "
                CREATE USER IF NOT EXISTS '$username'@'%' IDENTIFIED BY '$password';
                CREATE USER IF NOT EXISTS '$username'@'localhost' IDENTIFIED BY '$password';
                GRANT ALL PRIVILEGES ON $username.* TO '$username'@'%';
                GRANT ALL PRIVILEGES ON $username.* TO '$username'@'localhost';
                FLUSH PRIVILEGES;
            " 2>/dev/null; then
                log INFO "✓ User $username created successfully using root with password"
            else
                log ERROR "✗ Failed to create user $username even with root password"
                return 1
            fi
        else
            log ERROR "✗ Cannot create user $username - no root access available"
            log ERROR "Container may require manual database initialization"
            return 1
        fi
    fi

    # Verify that user can login with the password
    log INFO "Testing login for user $username..."
    if docker exec "$container" mysql -u "$username" -p"$password" -e "SELECT 1;" 2>/dev/null >/dev/null; then
        log INFO "✓ User $username can login successfully"
        return 0
    else
        log ERROR "✗ User $username cannot login with provided password"
        log ERROR "This may cause restore issues"
        return 1
    fi
}

restore_single_database() {
    local db_name="$1"
    local service_name="$2"
    local db_password="$3"
    local sql_file="$4"

    log INFO "Restoring $db_name database..."

    local container=$(docker compose ps -q "$service_name")
    if [[ -z "$container" ]]; then
        log ERROR "Container for $service_name not found"
        return 1
    fi

    # Verify SQL file exists and is readable
    if [[ ! -f "$sql_file" ]]; then
        log ERROR "SQL file not found: $sql_file"
        return 1
    fi

    if [[ ! -r "$sql_file" ]]; then
        log ERROR "SQL file not readable: $sql_file"
        return 1
    fi

    # Create database user if not exists (for fresh installations)
    case "$db_name" in
        "panelalpha")
            if ! setup_database_user "$container" "panelalpha" "$db_password"; then
                log ERROR "Failed to setup panelalpha user - cannot proceed with restore"
                return 1
            fi
            ;;
        "core")
            if ! setup_database_user "$container" "core" "$db_password"; then
                log ERROR "Failed to setup core user - cannot proceed with restore"
                return 1
            fi
            ;;
    esac

    # Drop and recreate database using the database user (not root)
    log INFO "Recreating $db_name database..."
    if docker exec "$container" mysql -u "$db_name" -p"$db_password" -e "DROP DATABASE IF EXISTS $db_name; CREATE DATABASE $db_name CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null; then
        log INFO "✓ Database $db_name recreated successfully using user $db_name"
    else
        log WARN "Failed to recreate database using user $db_name, trying alternative approach..."

        # Alternative: Just ensure database exists without dropping
        if docker exec "$container" mysql -u "$db_name" -p"$db_password" -e "CREATE DATABASE IF NOT EXISTS $db_name CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null; then
            log INFO "✓ Database $db_name ensured to exist"
        else
            log ERROR "✗ Failed to create/access database $db_name"
            return 1
        fi
    fi

    # Import data using the specific user
    log INFO "Importing $db_name database dump..."
    if docker exec -i "$container" mysql -u "$db_name" -p"$db_password" "$db_name" < "$sql_file" 2>/dev/null; then
        log INFO "✓ $db_name database imported successfully"
    else
        log ERROR "✗ $db_name database import failed"

        # Try with verbose error output using the specific user
        log INFO "Attempting import with error details..."
        if docker exec -i "$container" mysql -u "$db_name" -p"$db_password" "$db_name" < "$sql_file"; then
            log INFO "✓ $db_name database imported on retry"
        else
            log ERROR "✗ Import failed permanently for $db_name"
            log WARN "Database import failed - this may be due to privilege issues"
            return 1
        fi
    fi

    # Verify import using the specific user
    local table_count=$(docker exec "$container" mysql -u "$db_name" -p"$db_password" -e "USE $db_name; SHOW TABLES;" 2>/dev/null | wc -l)
    if [[ $table_count -gt 1 ]]; then
        log INFO "✓ $db_name database verification successful ($((table_count-1)) tables)"
    else
        log WARN "⚠ $db_name database appears empty after import (tables: $table_count)"
        log WARN "This may indicate import issues or empty snapshot file"
    fi

    return 0
}

update_system_settings() {
    # This function is only for Control Panel, skip for Engine
    if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
        log INFO "Skipping system settings update (not applicable for Engine)"
        return 0
    fi

    log INFO "Updating system settings for current server..."

    local api_password=$(grep "^API_MYSQL_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")

    if [[ -z "$api_password" ]]; then
        log WARN "Cannot update system settings - API_MYSQL_PASSWORD not found"
        return 1
    fi

    local api_container=$(docker compose ps -q database-api)
    if [[ -z "$api_container" ]]; then
        log ERROR "API database container not found"
        return 1
    fi

    # Get current server IP and hostname
    local server_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")
    local server_hostname=$(hostname 2>/dev/null || echo "localhost")

    log INFO "Current server IP: $server_ip"
    log INFO "Current hostname: $server_hostname"

    # Update host_ip_address
    log INFO "Updating host_ip_address in system_settings..."
    if docker exec "$api_container" mysql -u panelalpha -p"$api_password" panelalpha \
        -e "UPDATE system_settings SET value = '$server_ip' WHERE name = 'host_ip_address';" 2>/dev/null; then
        log INFO "✓ Updated host_ip_address to: $server_ip"
    else
        log WARN "✗ Failed to update host_ip_address"
    fi

    # Update trusted_hosts
    log INFO "Updating trusted_hosts in system_settings..."
    if docker exec "$api_container" mysql -u panelalpha -p"$api_password" panelalpha \
        -e "UPDATE system_settings SET value = '$server_hostname' WHERE name = 'trusted_hosts';" 2>/dev/null; then
        log INFO "✓ Updated trusted_hosts to: $server_hostname"
    else
        log WARN "✗ Failed to update trusted_hosts"
    fi

    # Verify updates
    log INFO "Verifying system settings updates..."
    local current_ip=$(docker exec "$api_container" mysql -u panelalpha -p"$api_password" panelalpha \
        -e "SELECT value FROM system_settings WHERE name = 'host_ip_address';" -s -N 2>/dev/null || echo "")
    local current_hosts=$(docker exec "$api_container" mysql -u panelalpha -p"$api_password" panelalpha \
        -e "SELECT value FROM system_settings WHERE name = 'trusted_hosts';" -s -N 2>/dev/null || echo "")

    if [[ "$current_ip" == "$server_ip" ]]; then
        log INFO "✓ host_ip_address verified: $current_ip"
    else
        log WARN "✗ host_ip_address verification failed: expected '$server_ip', got '$current_ip'"
    fi

    if [[ "$current_hosts" == "$server_hostname" ]]; then
        log INFO "✓ trusted_hosts verified: $current_hosts"
    else
        log WARN "✗ trusted_hosts verification failed: expected '$server_hostname', got '$current_hosts'"
    fi

    log INFO "System settings update completed"
}

restore_databases() {
    local data_dir="$1"

    log INFO "=== Enhanced Database Restore ==="

    cd "$PANELALPHA_DIR"

    if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
        log INFO "Restoring databases for PanelAlpha Engine"
        
        local core_password=$(grep "^CORE_MYSQL_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
        local users_password=$(grep "^USERS_MYSQL_ROOT_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")

        # Step 1: Completely stop all database containers
        log INFO "Stopping all database containers for clean restore..."
        docker compose stop database-core database-users 2>/dev/null || true
        sleep 5

        # Step 2: Clean database volumes for fresh start
        log WARN "Force cleaning database volumes to prevent InnoDB issues..."
        clean_database_volumes

        # Step 3: Start containers and wait for readiness
        log INFO "Starting database containers..."
        docker compose up -d database-core database-users

        if ! wait_for_database_containers_enhanced; then
            log ERROR "Database containers failed to start properly"
            log INFO "Attempting to clean volumes and restart..."
            clean_database_volumes
            docker compose up -d database-core database-users

            if ! wait_for_database_containers_enhanced; then
                log ERROR "Database containers still not ready after volume cleanup"
                return 1
            fi
        fi

        # Step 4: Restore Core database
        if [[ -f "$data_dir/databases/panelalpha-core.sql" && -n "$core_password" ]]; then
            log INFO "Found Core database snapshot and password"
            if ! restore_single_database "core" "database-core" "$core_password" "$data_dir/databases/panelalpha-core.sql"; then
                log ERROR "Core database restore failed"
                return 1
            fi
        else
            if [[ ! -f "$data_dir/databases/panelalpha-core.sql" ]]; then
                log WARN "Core database snapshot file not found"
            fi
            if [[ -z "$core_password" ]]; then
                log WARN "CORE_MYSQL_PASSWORD not found in $ENV_FILE"
            fi
        fi

        # Step 5: Restore Users database
        local users_dump_file=""
        if [[ -f "$data_dir/databases/panelalpha-users.sql.gz" ]]; then
            users_dump_file="$data_dir/databases/panelalpha-users.sql.gz"
        elif [[ -f "$data_dir/databases/panelalpha-users.sql" ]]; then
            users_dump_file="$data_dir/databases/panelalpha-users.sql"
        fi

        if [[ -n "$users_dump_file" && -n "$users_password" ]]; then
            log INFO "Found Users database snapshot and password"
            # For users database, we restore all databases as root
            local users_container=$(docker compose ps -q database-users)
            if [[ -n "$users_container" ]]; then
                if [[ "$users_dump_file" == *.gz ]]; then
                    log INFO "Importing Users databases dump (compressed)..."
                    if gunzip -c "$users_dump_file" | docker exec -i "$users_container" mysql -u root -p"$users_password" 2>/dev/null; then
                        log INFO "✓ Users databases imported successfully"
                    else
                        log ERROR "✗ Users databases import failed"
                        return 1
                    fi
                else
                    log INFO "Importing Users databases dump..."
                    if docker exec -i "$users_container" mysql -u root -p"$users_password" < "$users_dump_file" 2>/dev/null; then
                        log INFO "✓ Users databases imported successfully"
                    else
                        log ERROR "✗ Users databases import failed"
                        return 1
                    fi
                fi
            else
                log ERROR "Users database container not found"
                return 1
            fi
        else
            if [[ -z "$users_dump_file" ]]; then
                log WARN "Users database snapshot file not found"
            fi
            if [[ -z "$users_password" ]]; then
                log WARN "USERS_MYSQL_ROOT_PASSWORD not found in $ENV_FILE"
            fi
        fi

    else
        log INFO "Restoring databases for PanelAlpha Control Panel"
        
        local api_password=$(grep "^API_MYSQL_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")

        # Step 1: Completely stop all database containers
        log INFO "Stopping database container for clean restore..."
        docker compose stop database-api 2>/dev/null || true
        sleep 5

        # Step 2: Clean database volumes for fresh start
        log WARN "Force cleaning database volumes to prevent InnoDB issues..."
        clean_database_volumes

        # Step 3: Start containers and wait for readiness
        log INFO "Starting database container..."
        docker compose up -d database-api

        if ! wait_for_database_containers_enhanced; then
            log ERROR "Database container failed to start properly"
            log INFO "Attempting to clean volumes and restart..."
            clean_database_volumes
            docker compose up -d database-api

            if ! wait_for_database_containers_enhanced; then
                log ERROR "Database container still not ready after volume cleanup"
                return 1
            fi
        fi

        # Step 4: Restore PanelAlpha database
        if [[ -f "$data_dir/databases/panelalpha-api.sql" && -n "$api_password" ]]; then
            log INFO "Found PanelAlpha database snapshot and password"
            if ! restore_single_database "panelalpha" "database-api" "$api_password" "$data_dir/databases/panelalpha-api.sql"; then
                log ERROR "PanelAlpha database restore failed"
                return 1
            fi
        else
            if [[ ! -f "$data_dir/databases/panelalpha-api.sql" ]]; then
                log WARN "PanelAlpha database snapshot file not found"
            fi
            if [[ -z "$api_password" ]]; then
                log WARN "API_MYSQL_PASSWORD not found in $ENV_FILE"
            fi
        fi

        # Step 5: Update system settings for current server
        update_system_settings
    fi

    # Verify database integrity
    verify_database_integrity

    log INFO "Database restore completed successfully"
    return 0
}

verify_database_integrity() {
    log INFO "Verifying database integrity..."

    if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
        local core_container=$(docker compose ps -q database-core)
        local users_container=$(docker compose ps -q database-users)

        # Get passwords from ENV_FILE
        local core_password=$(grep "^CORE_MYSQL_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
        local users_password=$(grep "^USERS_MYSQL_ROOT_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")

        # Check Core database
        if [[ -n "$core_container" && -n "$core_password" ]]; then
            log INFO "Checking Core database integrity..."
            local core_tables=$(docker exec "$core_container" mysql -u core -p"$core_password" -e "USE core; SHOW TABLES;" 2>/dev/null | wc -l)
            if [[ $core_tables -gt 1 ]]; then
                log INFO "✓ Core database integrity OK ($((core_tables-1)) tables)"
            else
                log WARN "⚠ Core database may be empty or inaccessible"
            fi
        else
            log WARN "Cannot verify Core database - missing container or password"
        fi

        # Check Users database
        if [[ -n "$users_container" && -n "$users_password" ]]; then
            log INFO "Checking Users databases integrity..."
            local users_dbs=$(docker exec "$users_container" mysql -u root -p"$users_password" -e "SHOW DATABASES;" 2>/dev/null | wc -l)
            if [[ $users_dbs -gt 1 ]]; then
                log INFO "✓ Users databases integrity OK ($((users_dbs-1)) databases)"
            else
                log WARN "⚠ Users databases may be empty or inaccessible"
            fi
        else
            log WARN "Cannot verify Users databases - missing container or password"
        fi
    else
        local api_container=$(docker compose ps -q database-api)

        # Get passwords from ENV_FILE
        local api_password=$(grep "^API_MYSQL_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")

        # Check API database
        if [[ -n "$api_container" && -n "$api_password" ]]; then
            log INFO "Checking PanelAlpha database integrity..."
            local api_tables=$(docker exec "$api_container" mysql -u panelalpha -p"$api_password" -e "USE panelalpha; SHOW TABLES;" 2>/dev/null | wc -l)
            if [[ $api_tables -gt 1 ]]; then
                log INFO "✓ PanelAlpha database integrity OK ($((api_tables-1)) tables)"
            else
                log WARN "⚠ PanelAlpha database may be empty or inaccessible"
            fi
        else
            log WARN "Cannot verify PanelAlpha database - missing container or password"
        fi
    fi
}

restore_volumes() {
    local data_dir="$1"

    log INFO "Restoring volumes..."

    cd "$PANELALPHA_DIR"

    # Define volumes based on application type
    local volumes=()
    if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
        volumes=("core-storage" "database-core-data" "database-users-data")
    else
        volumes=("api-storage" "database-api-data" "redis-data")
    fi

    for volume in "${volumes[@]}"; do
        local volume_file="$data_dir/volumes/$volume.tar.gz"
        local full_name="${PWD##*/}_$volume"

        if [[ -f "$volume_file" ]]; then
            log INFO "Restoring volume: $volume"
            docker volume create "$full_name" 2>/dev/null || true
            docker run --rm \
                -v "$full_name":/target \
                -v "$data_dir/volumes":/backup:ro \
                ubuntu:20.04 \
                tar xzf "/backup/$volume.tar.gz" -C /target
        fi
    done
}

restore_config() {
    local data_dir="$1"

    log INFO "Restoring configuration files..."

    cd "$PANELALPHA_DIR"

    # Restore configuration files
    if [[ -d "$data_dir/config" ]]; then
        log INFO "Restoring configuration files..."

        # Restore docker-compose.yml
        if [[ -f "$data_dir/config/docker-compose.yml" ]]; then
            cp "$data_dir/config/docker-compose.yml" . 2>/dev/null || true
        fi

        # Restore nginx configs
        cp "$data_dir/config/nginx.conf"* . 2>/dev/null || true

        # Restore Dockerfiles
        cp "$data_dir/config/Dockerfile"* . 2>/dev/null || true

        # Restore packages directory
        if [[ -d "$data_dir/config/packages" ]]; then
            log INFO "Restoring packages directory..."
            if command -v rsync &> /dev/null; then
                rsync -av "$data_dir/config/packages/" "packages/" 2>/dev/null || true
            else
                cp -r "$data_dir/config/packages" . 2>/dev/null || true
            fi
        fi

        # Restore environment file (supports legacy .env-core backups)
        local snapshot_env_file="$data_dir/config/$ENV_FILE_NAME"
        local restore_env_target="$ENV_FILE_NAME"

        if [[ ! -f "$snapshot_env_file" && "$PANELALPHA_APP_TYPE" == "engine" && "$ENV_FILE_NAME" == ".env" ]]; then
            local legacy_env_file="$data_dir/config/.env-core"
            if [[ -f "$legacy_env_file" ]]; then
                snapshot_env_file="$legacy_env_file"
                restore_env_target=".env-core"
            fi
        fi

        if [[ -f "$snapshot_env_file" ]]; then
            log INFO "Restoring ${restore_env_target} configuration from backup..."
            cp "$snapshot_env_file" "$restore_env_target"
            log INFO "${restore_env_target} file restored from backup ✓"
            rm -f "${restore_env_target}.current-backup"
        else
            log WARN "No ${restore_env_target} file found in backup, keeping current configuration"
        fi

        # Restore SSL certificates
        if [[ -d "$data_dir/config/ssl/letsencrypt" ]]; then
            log INFO "Restoring SSL certificates..."
            mkdir -p /etc/letsencrypt
            cp -r "$data_dir/config/ssl/letsencrypt/"* /etc/letsencrypt/ 2>/dev/null || true
        fi
    fi

    log INFO "Configuration files restored from backup ✓"
}

restore_users() {
    local data_dir="$1"

    if [[ "$PANELALPHA_APP_TYPE" != "engine" ]]; then
        log DEBUG "Skipping user container restore for application type: $PANELALPHA_APP_TYPE"
        return 0
    fi

    local source_dir="$data_dir/users"
    if [[ ! -d "$source_dir" ]]; then
        log INFO "No user container data found in snapshot - skipping"
        return 0
    fi

    local target_dir="${PANELALPHA_DIR}/users"
    mkdir -p "$target_dir"

    log INFO "Restoring user container projects to $target_dir"
    local users_restore_success=true

    if command -v rsync &> /dev/null; then
        if rsync -a "$source_dir/" "$target_dir/" 2>/dev/null; then
            log INFO "✓ User container projects restored"
        else
            log ERROR "✗ Failed to restore user container projects with rsync"
            users_restore_success=false
        fi
    else
        if cp -a "$source_dir/." "$target_dir/" 2>/dev/null; then
            log INFO "✓ User container projects restored (using cp)"
        else
            log ERROR "✗ Failed to restore user container projects"
            users_restore_success=false
        fi
    fi

    if [[ "$users_restore_success" == true ]]; then
        return 0
    fi

    return 1
}

restore_home_directory() {
    local data_dir="$1"

    if [[ "$PANELALPHA_APP_TYPE" != "engine" ]]; then
        log DEBUG "Skipping /home restore for application type: $PANELALPHA_APP_TYPE"
        return 0
    fi

    local source_dir="$data_dir/home"
    if [[ ! -d "$source_dir" ]]; then
        log INFO "No /home snapshot found - skipping"
        return 0
    fi

    mkdir -p /home

    log INFO "Restoring /home directory (existing files may be overwritten)..."
    local home_restore_success=true

    if command -v rsync &> /dev/null; then
        if rsync -a --numeric-ids "$source_dir/" "/home/" 2>/dev/null; then
            log INFO "✓ /home directory restored"
        else
            log ERROR "✗ Failed to restore /home directory with rsync"
            home_restore_success=false
        fi
    else
        if cp -a "$source_dir/." "/home/" 2>/dev/null; then
            log INFO "✓ /home directory restored (using cp)"
        else
            log ERROR "✗ Failed to restore /home directory"
            home_restore_success=false
        fi
    fi

    if [[ "$home_restore_success" == true ]]; then
        return 0
    fi

    return 1
}

restore_from_snapshot() {
    local snapshot_id="$1"

    if [[ -z "$snapshot_id" ]]; then
        log ERROR "Snapshot ID is required"
        log ERROR "Usage: $0 --restore <snapshot_id>"
        exit 1
    fi

    log INFO "=== Restoring from Snapshot: $snapshot_id ==="

    check_requirements
    resolve_snapshot "$snapshot_id"

    mkdir -p "$RESTORE_TEMP_DIR"
    trap "rm -rf '$RESTORE_TEMP_DIR'" EXIT

    restore_snapshot "$SNAPSHOT_ID" "$RESTORE_TEMP_DIR"

    # Find data directory
    local data_dir="$RESTORE_TEMP_DIR"
    if [[ -d "$RESTORE_TEMP_DIR/tmp" ]]; then
        data_dir=$(find "$RESTORE_TEMP_DIR/tmp" -name "pasnap-snapshot-*" -type d | head -1)
    fi

    if [[ ! -d "$data_dir" ]]; then
        log ERROR "Cannot find snapshot data in repository"
        log ERROR "Snapshot may be corrupted or incompatible"
        exit 1
    fi

    log INFO "Found snapshot data from: $(cat "$data_dir/snapshot-info.txt" 2>/dev/null | grep "Created:" || echo "Unknown date")"

    # Confirm restore
    echo
    log WARN "This will completely replace current PanelAlpha installation"
    log WARN "All current data will be lost!"
    echo
    read -p "Are you sure you want to continue with restore? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log INFO "Restore cancelled"
        return 0
    fi

    cd "$PANELALPHA_DIR"

    # Step 1: Stop all services
    log INFO "Stopping PanelAlpha services..."
    docker compose down
    sleep 10

    # Step 2: Clean database volumes for fresh start
    log INFO "Cleaning database volumes for fresh restore..."
    clean_database_volumes

    # Step 3: Restore configuration files
    log INFO "Restoring configuration files..."
    restore_config "$data_dir"

    # Step 4: Restore databases (function handles container startup)
    log INFO "Restoring databases..."
    restore_databases "$data_dir"

    # Step 6: Restore volumes
    log INFO "Restoring volumes..."
    restore_volumes "$data_dir"

    # Step 7 & 8: Restore user data for engine deployments
    if [[ "$PANELALPHA_APP_TYPE" == "engine" ]]; then
        log INFO "Restoring user container projects..."
        if ! restore_users "$data_dir"; then
            log ERROR "User container restore failed"
            exit 1
        fi

        log INFO "Restoring /home directory..."
        if ! restore_home_directory "$data_dir"; then
            log ERROR "/home directory restore failed"
            exit 1
        fi
    fi

    # Step 9: Start all services
    log INFO "Starting all PanelAlpha services..."
    docker compose up -d

    # Step 10: Wait for services to be ready
    log INFO "Waiting for services to start..."
    sleep 30

    # Step 11: Verify restoration
    log INFO "Verifying restoration..."
    if docker compose ps | grep -q "Up"; then
        log INFO "✓ PanelAlpha services are running"
    else
        log WARN "Some services may not be running properly"
        log INFO "Check status with: docker compose ps"
    fi

    log INFO "=== Restore completed successfully ✓ ==="
    log INFO "PanelAlpha has been restored from snapshot: $SNAPSHOT_ID"
}

# ======================
# CRON AUTOMATION MANAGEMENT
# ======================

# Manage automatic snapshot scheduling
manage_cron() {
    local action="$1"

    case "$action" in
        install)
            install_cron_job
            ;;
        remove)
            remove_cron_job
            ;;
        status)
            show_cron_status
            ;;
        *)
            log ERROR "Invalid cron action: $action"
            log ERROR "Valid actions: install, remove, status"
            exit 1
            ;;
    esac
}

# Install automatic snapshot cron job
install_cron_job() {
    log INFO "=== Installing Automatic Snapshot Schedule ==="

    check_root

    # Validate configuration exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log ERROR "Configuration file not found: $CONFIG_FILE"
        log ERROR "Please run: $0 --setup"
        exit 1
    fi

    # Load configuration to get backup hour
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    local backup_hour="${BACKUP_HOUR:-2}"

    # Validate backup hour
    if ! [[ "$backup_hour" =~ ^[0-9]+$ ]] || [[ $backup_hour -lt 0 ]] || [[ $backup_hour -gt 23 ]]; then
        log WARN "Invalid backup hour in config: $backup_hour, using default: 2"
        backup_hour=2
    fi

    local cron_line="0 $backup_hour * * * $SCRIPT_DIR/pasnap.sh --snapshot >> $LOG_FILE 2>&1"

    # Check if cron entry already exists
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/pasnap.sh"; then
        log WARN "Automatic snapshot cron job already exists"
        log INFO "Current entry:"
        crontab -l 2>/dev/null | grep "$SCRIPT_DIR/pasnap.sh" || true

        read -p "Do you want to replace it? (yes/no): " replace
        if [[ "$replace" != "yes" ]]; then
            log INFO "Installation cancelled"
            return 0
        fi

        # Remove existing entry
        if crontab -l 2>/dev/null | grep -v "$SCRIPT_DIR/pasnap.sh" | crontab -; then
            log INFO "✓ Existing cron job removed"
        else
            log ERROR "Failed to remove existing cron job"
            exit 1
        fi
    fi

    # Add new cron entry
    if (crontab -l 2>/dev/null; echo "$cron_line") | crontab -; then
        log INFO "✓ Automatic snapshot schedule installed"
        log INFO "Schedule: Daily at ${backup_hour}:00"
        log INFO "Log file: $LOG_FILE"
        log INFO "Command: $cron_line"
    else
        log ERROR "Failed to install cron job"
        exit 1
    fi
}

# Remove automatic snapshot cron job
remove_cron_job() {
    log INFO "=== Removing Automatic Snapshot Schedule ==="

    check_root

    if ! crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/pasnap.sh"; then
        log INFO "No automatic snapshot cron job found"
        return 0
    fi

    # Remove cron entry
    if crontab -l 2>/dev/null | grep -v "$SCRIPT_DIR/pasnap.sh" | crontab -; then
        log INFO "✓ Automatic snapshot schedule removed"
    else
        log ERROR "Failed to remove cron job"
        exit 1
    fi
}

# Show current cron status and recent activity
show_cron_status() {
    log INFO "=== Automatic Snapshot Status ==="

    if crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/pasnap.sh"; then
        echo "✓ Automatic snapshots are ENABLED"
        echo
        echo "Current schedule:"
        crontab -l 2>/dev/null | grep "$SCRIPT_DIR/pasnap.sh" || echo "  (could not retrieve)"
        echo
        echo "Log file: $LOG_FILE"

        # Show recent log entries if available
        if [[ -f "$LOG_FILE" ]]; then
            echo
            echo "Recent snapshot activity (last 10 entries):"
            echo "----------------------------------------"
            tail -10 "$LOG_FILE" 2>/dev/null || echo "  No recent activity found"
        else
            echo
            echo "Log file not found - no recent activity"
        fi
    else
        echo "✗ Automatic snapshots are DISABLED"
        echo
        echo "To enable automatic snapshots:"
        echo "  $0 --cron install"
    fi
    echo
}

# ======================
# MAIN ENTRY POINT
# ======================

main() {
    # Set up error handling
    set -euo pipefail
    
    # Check for updates before running any commands
    # This may restart the script with new version if user accepts update
    check_for_updates "$@"
    
    # Validate input arguments
    if [[ $# -eq 0 ]]; then
        log INFO "🔧 PanelAlpha Snapshot Tool v$SCRIPT_VERSION"
        echo "No arguments provided. Use --help to see available options."
        echo ""
        echo "Quick start:"
        echo "  1. sudo $0 --install     # Install tools"
        echo "  2. sudo $0 --setup       # Configure"
        echo "  3. sudo $0 --snapshot    # Create snapshot"
        echo ""
        echo "Full help: sudo $0 --help"
        exit 0
    fi

    # Parse command line arguments with validation
    case "${1:-}" in
        --install)
            log INFO "🔧 Starting tool installation..."
            install_dependencies
            ;;
        --setup)
            log INFO "⚙️ Starting configuration..."
            setup_config
            ;;
        --snapshot)
            log INFO "📸 Starting snapshot creation..."
            create_snapshot
            ;;
        --snapshot-bg)
            log INFO "📸 Starting snapshot creation in background..."
            # Run snapshot in background with nohup to survive terminal closure
            nohup bash -c "exec $0 --snapshot" >> "$LOG_FILE" 2>&1 &
            local nohup_pid=$!
            disown $nohup_pid 2>/dev/null || true
            
            # Wait a moment for the actual bash process to spawn
            sleep 0.5
            
            # Find the actual snapshot bash process (child of nohup)
            local bg_pid
            bg_pid=$(pgrep -P "$nohup_pid" 2>/dev/null || echo "$nohup_pid")
            
            # If still not found, use nohup PID
            if [[ -z "$bg_pid" ]]; then
                bg_pid=$nohup_pid
            fi
            
            log INFO "📸 Snapshot process started in background (PID: $bg_pid)"
            log INFO "💡 Process will continue even if terminal closes"
            log INFO "💡 Check progress with: tail -f $LOG_FILE"
            ;;
        --test-connection)
            log INFO "🔍 Testing repository connection..."
            test_repository_connection
            ;;
        --restore)
            if [[ -z "${2:-}" ]]; then
                log ERROR "❌ Snapshot ID is required for restore operation"
                log ERROR "Usage: $0 --restore <snapshot_id>"
                log ERROR "Use '$0 --list-snapshots' to see available snapshots"
                echo ""
                echo "Examples:"
                echo "  sudo $0 --restore latest      # Restore latest"
                echo "  sudo $0 --restore a1b2c3d4    # Restore specific"
                exit 1
            fi
            if ! validate_input "$2" "snapshot_id"; then
                exit 1
            fi
            log INFO "🔄 Starting restore from snapshot: $2"
            restore_from_snapshot "$2"
            ;;
        --list-snapshots)
            log INFO "📋 Displaying available snapshots..."
            list_snapshots
            ;;
        --delete-snapshots)
            if [[ -z "${2:-}" ]]; then
                log ERROR "❌ Snapshot ID is required for delete operation"
                log ERROR "Usage: $0 --delete-snapshots <snapshot_id>"
                log ERROR "Use '$0 --list-snapshots' to see available snapshots"
                exit 1
            fi
            if ! validate_input "$2" "snapshot_id"; then
                exit 1
            fi
            log WARN "🗑️ Deleting snapshot: $2"
            delete_snapshot "$2"
            ;;
        --cron)
            if [[ -z "${2:-}" ]]; then
                log ERROR "❌ Cron action is required"
                log ERROR "Usage: $0 --cron [install|remove|status]"
                echo ""
                echo "Available actions:"
                echo "  install - Install automatic snapshots"
                echo "  remove  - Remove automatic snapshots"  
                echo "  status  - Check automation status"
                exit 1
            fi
            if [[ ! "$2" =~ ^(install|remove|status)$ ]]; then
                log ERROR "❌ Invalid cron action: $2"
                log ERROR "Available actions: install, remove, status"
                exit 1
            fi
            log INFO "🤖 Managing cron automation: $2"
            manage_cron "$2"
            ;;
        --version)
            show_version
            ;;
        --help|-h)
            show_help
            ;;
        *)
            log ERROR "❌ Unknown option: $1"
            echo ""
            log INFO "💡 Use '$0 --help' to see available options"
            echo ""
            echo "Most commonly used commands:"
            echo "  sudo $0 --snapshot           # Create snapshot"
            echo "  sudo $0 --list-snapshots     # View snapshots"
            echo "  sudo $0 --restore latest     # Restore latest"
            exit 1
            ;;
    esac
}

# Error handling for the entire script
error_handler() {
    local exit_code=$?
    local line_number=$1
    
    log ERROR "❌ An unexpected error occurred at line $line_number (code: $exit_code)"
    log ERROR "Check logs at: /var/log/pasnap.log"
    log ERROR "Use '$0 --help' for help"
    
    # Cleanup if needed
    cleanup_temp_dir
    
    exit $exit_code
}

# Set up error trap
trap 'error_handler $LINENO' ERR

# Execute main function with all provided arguments
main "$@"
