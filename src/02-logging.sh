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

