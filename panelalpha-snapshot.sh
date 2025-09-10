#!/bin/bash

# PanelAlpha Create Snapshot & Restore Script v1.0
# Professional script for creating snapshots and restoring PanelAlpha application using Restic
# Usage: ./panelalpha-snapshot.sh [options]

set -euo pipefail

# ======================
# CONFIGURATION CONSTANTS
# ======================

readonly SCRIPT_VERSION="1.1"
readonly SCRIPT_NAME="PanelAlpha Create Snapshot & Restore Script"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PANELALPHA_DIR="/opt/panelalpha/app"
readonly CONFIG_FILE="${PANELALPHA_DIR}/.env-backup"

# Security constants
readonly MYSQL_TIMEOUT=30
readonly MAX_RETRY_ATTEMPTS=3

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
    
    # Also log to file if LOG_FILE is set and writable
    if [[ -n "${LOG_FILE:-}" ]] && [[ -w "$(dirname "$LOG_FILE")" || -w "$LOG_FILE" ]]; then
        echo "[$timestamp] $level: $message" >> "$LOG_FILE"
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
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        set -a
        source "$CONFIG_FILE"
        set +a
        log DEBUG "Configuration loaded from $CONFIG_FILE"
    else
        log DEBUG "No configuration file found at $CONFIG_FILE"
    fi

    # Set default values with parameter expansion
    BACKUP_TEMP_DIR="${BACKUP_TEMP_DIR:-/var/tmp}/panelalpha-snapshot-$(date +%Y%m%d-%H%M%S)"
    RESTORE_TEMP_DIR="${RESTORE_TEMP_DIR:-/var/tmp}/panelalpha-restore-$(date +%Y%m%d-%H%M%S)"
    LOG_FILE="${LOG_FILE:-/var/log/panelalpha-snapshot.log}"
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
    BACKUP_TAG="${BACKUP_TAG_PREFIX:-panelalpha}-$(hostname)"
    RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"
}

# Initialize configuration on script load
load_configuration

# ======================
# MAIN FUNCTIONS
# ======================

# ======================
# HELP AND VERSION FUNCTIONS
# ======================

show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION

🚀 USAGE: $0 [option]

📦 INSTALLATION AND CONFIGURATION:
  --install             Install all required tools
  --setup               Interactive configuration (repository, authentication)

📸 SNAPSHOT OPERATIONS:
  --snapshot            Create new snapshot
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
  For issues check logs: /var/log/panelalpha-snapshot.log
  
EOF
}

show_version() {
    echo "🚀 $SCRIPT_NAME v$SCRIPT_VERSION"
    echo "Professional solution for creating snapshots and restoring PanelAlpha"
    echo "Uses Restic for secure, incremental backups"
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
    echo "Copyright (c) $(date +%Y) - Open Source License"
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
            read -p "Path prefix in bucket (e.g. panelalpha-snapshots): " s3_prefix
            s3_prefix=${s3_prefix:-panelalpha-snapshots}

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
LOG_FILE="$LOG_FILE"
BACKUP_TEMP_DIR="/var/tmp"
RESTIC_CACHE_DIR="/var/cache/restic"

# PanelAlpha application settings
PANELALPHA_DIR="/opt/panelalpha/app"
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

    # Extract database passwords from environment file securely
    local api_password
    local matomo_password
    api_password=$(grep "^API_MYSQL_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' | head -1 || echo "")
    matomo_password=$(grep "^MATOMO_MYSQL_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' | head -1 || echo "")

    local snapshot_success=true
    local total_steps=2
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
                log ERROR "Check database password in .env file"
                snapshot_success=false
            fi
        fi
    else
        log WARN "API_MYSQL_PASSWORD not found - skipping PanelAlpha database"
        current_step=$total_steps  # Skip progress for this step
    fi

    # Snapshot Matomo database
    if [[ -n "$matomo_password" ]]; then
        if [[ -n "$api_password" ]]; then
            ((current_step++))
        else
            current_step=$total_steps  # If API was skipped, this is the only step
        fi
        show_progress $current_step $total_steps "Creating Matomo database snapshot"
        
        local matomo_container
        matomo_container=$(docker compose ps -q database-matomo 2>/dev/null)

        if [[ -z "$matomo_container" ]]; then
            log ERROR "Matomo database container not found"
            snapshot_success=false
        else
            # Test database connectivity with timeout
            if timeout "$MYSQL_TIMEOUT" docker exec "$matomo_container" mysql -u matomo -p"$matomo_password" -e "SELECT 1;" >/dev/null 2>&1; then
                log DEBUG "Matomo database connection verified"

                # Create database dump
                local dump_file="$snapshot_dir/databases/matomo.sql"
                if timeout 300 docker exec "$matomo_container" \
                    mysqldump -u matomo -p"$matomo_password" matomo \
                    --single-transaction --routines --triggers --lock-tables=false \
                    --add-drop-database --create-options --disable-keys \
                    --extended-insert --quick --set-charset \
                    > "$dump_file" 2>/dev/null; then

                    # Verify snapshot file integrity
                    if verify_file_integrity "$dump_file" 1000; then
                        local matomo_size
                        matomo_size=$(stat -c%s "$dump_file" 2>/dev/null || echo "0")
                        log INFO "✓ Matomo database snapshot created ($(( matomo_size / 1024 )) KB)"
                    else
                        log ERROR "✗ Matomo database snapshot is corrupted"
                        snapshot_success=false
                    fi
                else
                    log ERROR "✗ Matomo database snapshot failed"
                    snapshot_success=false
                fi
            else
                log ERROR "✗ Cannot connect to Matomo database"
                log ERROR "Check database password in .env file"
                snapshot_success=false
            fi
        fi
    else
        log WARN "MATOMO_MYSQL_PASSWORD not found - skipping Matomo database"
    fi

    # Final verification and summary
    if [[ "$snapshot_success" == true ]]; then
        local total_size
        total_size=$(du -sh "$snapshot_dir/databases" 2>/dev/null | cut -f1 || echo "0")
        log INFO "Database snapshots completed - size: $total_size"

        # Log database verification info
        log DEBUG "Database snapshot verification:"
        if [[ -f "$snapshot_dir/databases/panelalpha-api.sql" ]]; then
            local api_lines
            api_lines=$(wc -l < "$snapshot_dir/databases/panelalpha-api.sql" 2>/dev/null || echo "0")
            log DEBUG "  PanelAlpha: $api_lines lines"
        fi
        if [[ -f "$snapshot_dir/databases/matomo.sql" ]]; then
            local matomo_lines
            matomo_lines=$(wc -l < "$snapshot_dir/databases/matomo.sql" 2>/dev/null || echo "0")
            log DEBUG "  Matomo: $matomo_lines lines"
        fi
        
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

    # Define critical volumes for PanelAlpha
    local volumes=(
        "api-storage"
        "database-api-data"
        "database-matomo-data"
        "redis-data"
        "matomo"
    )

    local volumes_processed=0
    local volumes_total=${#volumes[@]}

    for volume in "${volumes[@]}"; do
        local full_volume_name="${PWD##*/}_$volume"
        
        if docker volume inspect "$full_volume_name" &> /dev/null; then
            log INFO "Creating snapshot of volume: $volume"
            
            # Create volume snapshot using temporary container
            if docker run --rm \
                -v "$full_volume_name":/source:ro \
                -v "$snapshot_dir/volumes":/target \
                ubuntu:20.04 \
                tar czf "/target/$volume.tar.gz" -C /source . 2>/dev/null; then
                
                ((volumes_processed++))
                log INFO "✓ Volume $volume snapshot created"
            else
                log WARN "✗ Failed to create snapshot for volume: $volume"
            fi
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
        ".env"
        ".env-backup"
        "nginx.conf"
        "Dockerfile"
    )

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
    
    local snapshot_result
    snapshot_result=$(restic backup "$BACKUP_TEMP_DIR" \
        --repo "$RESTIC_REPOSITORY" \
        --tag "$BACKUP_TAG" \
        --tag "databases" \
        --tag "volumes" \
        --tag "config" \
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
        snapshot_id=$(echo "$snapshot_result" | jq -r '.snapshot_id' 2>/dev/null || echo "")
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

Components Included:
- Databases (PanelAlpha API, Matomo)
- Docker volumes (api-storage, database-api-data, database-matomo-data, redis-data, matomo)
- Configuration files (docker-compose.yml, .env, packages/, SSL certificates)

Verification:
- Database dumps verified for minimum size
- File integrity checked
- Docker volumes archived with compression

Recovery Instructions:
1. Install PanelAlpha on target server
2. Copy this snapshot tool to target server
3. Configure snapshot repository (same settings)
4. Run: sudo ./panelalpha-snapshot.sh --restore <snapshot-id>

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

    local api_container=$(docker compose ps -q database-api)
    local matomo_container=$(docker compose ps -q database-matomo)

    if [[ -z "$api_container" || -z "$matomo_container" ]]; then
        log ERROR "One or both database containers are not running"
        return 1
    fi

    local max_attempts=120
    local attempt=0

    log INFO "Checking if MySQL/MariaDB processes are running and ready to accept connections..."

    while [[ $attempt -lt $max_attempts ]]; do
        local api_ready=false
        local matomo_ready=false

        # Check API database - just basic MySQL connectivity without authentication
        if docker exec "$api_container" mysqladmin ping --silent 2>/dev/null; then
            log DEBUG "API database is responding to ping"
            api_ready=true
        else
            log DEBUG "API database not ready yet"
        fi

        # Check Matomo database
        if docker exec "$matomo_container" mysqladmin ping --silent 2>/dev/null; then
            log DEBUG "Matomo database is responding to ping"
            matomo_ready=true
        else
            log DEBUG "Matomo database not ready yet"
        fi

        if [[ "$api_ready" == "true" && "$matomo_ready" == "true" ]]; then
            log INFO "Both database containers are ready"
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
    log ERROR "API container logs:"
    docker logs "$api_container" --tail 10 2>/dev/null || true
    log ERROR "Matomo container logs:"
    docker logs "$matomo_container" --tail 10 2>/dev/null || true

    return 1
}

clean_database_volumes() {
    log INFO "Cleaning database volumes..."

    cd "$PANELALPHA_DIR"

    # Get volume names
    local api_volume="${PWD##*/}_database-api-data"
    local matomo_volume="${PWD##*/}_database-matomo-data"

    # Remove API database volume
    if docker volume inspect "$api_volume" &> /dev/null; then
        log INFO "Removing API database volume: $api_volume"
        docker volume rm "$api_volume" 2>/dev/null || log WARN "Could not remove API volume (may not exist)"
    fi

    # Remove Matomo database volume
    if docker volume inspect "$matomo_volume" &> /dev/null; then
        log INFO "Removing Matomo database volume: $matomo_volume"
        docker volume rm "$matomo_volume" 2>/dev/null || log WARN "Could not remove Matomo volume (may not exist)"
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

    # If still empty, check the .env file for database passwords
    if [[ -z "$root_password" ]]; then
        root_password=$(grep "^DATABASE_ROOT_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
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
        "matomo")
            if ! setup_database_user "$container" "matomo" "$db_password"; then
                log ERROR "Failed to setup matomo user - cannot proceed with restore"
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
    log INFO "Updating system settings for current server..."

    local api_password=$(grep "^API_MYSQL_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")

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

    local api_password=$(grep "^API_MYSQL_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
    local matomo_password=$(grep "^MATOMO_MYSQL_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")

    # Step 1: Completely stop all database containers
    log INFO "Stopping all database containers for clean restore..."
    docker compose stop database-api database-matomo 2>/dev/null || true
    sleep 5

    # Step 2: Clean database volumes for fresh start
    log WARN "Force cleaning database volumes to prevent InnoDB issues..."
    clean_database_volumes

    # Step 3: Start containers and wait for readiness
    log INFO "Starting database containers..."
    docker compose up -d database-api database-matomo

    if ! wait_for_database_containers_enhanced; then
        log ERROR "Database containers failed to start properly"
        log INFO "Attempting to clean volumes and restart..."
        clean_database_volumes
        docker compose up -d database-api database-matomo

        if ! wait_for_database_containers_enhanced; then
            log ERROR "Database containers still not ready after volume cleanup"
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
            log WARN "API_MYSQL_PASSWORD not found in .env"
        fi
    fi

    # Step 5: Restore Matomo database
    if [[ -f "$data_dir/databases/matomo.sql" && -n "$matomo_password" ]]; then
        log INFO "Found Matomo database snapshot and password"
        if ! restore_single_database "matomo" "database-matomo" "$matomo_password" "$data_dir/databases/matomo.sql"; then
            log ERROR "Matomo database restore failed"
            return 1
        fi
    else
        if [[ ! -f "$data_dir/databases/matomo.sql" ]]; then
            log WARN "Matomo database snapshot file not found"
        fi
        if [[ -z "$matomo_password" ]]; then
            log WARN "MATOMO_MYSQL_PASSWORD not found in .env"
        fi
    fi

    # Step 6: Update system settings for current server
    update_system_settings

    # Step 7: Verify database integrity
    verify_database_integrity

    log INFO "Database restore completed successfully"
    return 0
}

verify_database_integrity() {
    log INFO "Verifying database integrity..."

    local api_container=$(docker compose ps -q database-api)
    local matomo_container=$(docker compose ps -q database-matomo)

    # Get passwords from .env
    local api_password=$(grep "^API_MYSQL_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
    local matomo_password=$(grep "^MATOMO_MYSQL_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")

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

    # Check Matomo database
    if [[ -n "$matomo_container" && -n "$matomo_password" ]]; then
        log INFO "Checking Matomo database integrity..."
        local matomo_tables=$(docker exec "$matomo_container" mysql -u matomo -p"$matomo_password" -e "USE matomo; SHOW TABLES;" 2>/dev/null | wc -l)
        if [[ $matomo_tables -gt 1 ]]; then
            log INFO "✓ Matomo database integrity OK ($((matomo_tables-1)) tables)"
        else
            log WARN "⚠ Matomo database may be empty or inaccessible"
        fi
    else
        log WARN "Cannot verify Matomo database - missing container or password"
    fi
}

restore_volumes() {
    local data_dir="$1"

    log INFO "Restoring volumes..."

    cd "$PANELALPHA_DIR"

    local volumes=("api-storage" "database-api-data" "database-matomo-data" "redis-data" "matomo")

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

        # Restore .env file directly from backup
        if [[ -f "$data_dir/config/.env" ]]; then
            log INFO "Restoring .env configuration from backup..."
            cp "$data_dir/config/.env" .env
            log INFO ".env file restored from backup ✓"

            # Clean up backup
            rm -f .env.current-backup
        else
            log WARN "No .env file found in backup, keeping current configuration"
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
        data_dir=$(find "$RESTORE_TEMP_DIR/tmp" -name "panelalpha-snapshot-*" -type d | head -1)
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

    # Step 4: Start database containers
    log INFO "Starting database containers..."
    docker compose up -d database-api database-matomo

    # Step 5: Wait for databases and restore data
    log INFO "Restoring databases..."
    restore_databases "$data_dir"

    # Step 6: Restore volumes
    log INFO "Restoring volumes..."
    restore_volumes "$data_dir"

    # Step 7: Start all services
    log INFO "Starting all PanelAlpha services..."
    docker compose up -d

    # Step 8: Wait for services to be ready
    log INFO "Waiting for services to start..."
    sleep 30

    # Step 9: Verify restoration
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

    local cron_line="0 $backup_hour * * * $SCRIPT_DIR/panelalpha-snapshot.sh --snapshot >> $LOG_FILE 2>&1"

    # Check if cron entry already exists
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/panelalpha-snapshot.sh"; then
        log WARN "Automatic snapshot cron job already exists"
        log INFO "Current entry:"
        crontab -l 2>/dev/null | grep "$SCRIPT_DIR/panelalpha-snapshot.sh" || true

        read -p "Do you want to replace it? (yes/no): " replace
        if [[ "$replace" != "yes" ]]; then
            log INFO "Installation cancelled"
            return 0
        fi

        # Remove existing entry
        if crontab -l 2>/dev/null | grep -v "$SCRIPT_DIR/panelalpha-snapshot.sh" | crontab -; then
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

    if ! crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/panelalpha-snapshot.sh"; then
        log INFO "No automatic snapshot cron job found"
        return 0
    fi

    # Remove cron entry
    if crontab -l 2>/dev/null | grep -v "$SCRIPT_DIR/panelalpha-snapshot.sh" | crontab -; then
        log INFO "✓ Automatic snapshot schedule removed"
    else
        log ERROR "Failed to remove cron job"
        exit 1
    fi
}

# Show current cron status and recent activity
show_cron_status() {
    log INFO "=== Automatic Snapshot Status ==="

    if crontab -l 2>/dev/null | grep -q "$SCRIPT_DIR/panelalpha-snapshot.sh"; then
        echo "✓ Automatic snapshots are ENABLED"
        echo
        echo "Current schedule:"
        crontab -l 2>/dev/null | grep "$SCRIPT_DIR/panelalpha-snapshot.sh" || echo "  (could not retrieve)"
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
    log ERROR "Check logs at: /var/log/panelalpha-snapshot.log"
    log ERROR "Use '$0 --help' for help"
    
    # Cleanup if needed
    cleanup_temp_dir
    
    exit $exit_code
}

# Set up error trap
trap 'error_handler $LINENO' ERR

# Execute main function with all provided arguments
main "$@"