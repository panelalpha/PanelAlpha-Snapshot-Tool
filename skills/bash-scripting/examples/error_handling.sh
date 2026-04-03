#!/bin/bash
# Example: Error Handling Pattern
# Demonstrates proper error handling in pasnap.sh style

set -euo pipefail

# Colors for output
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_NC='\033[0m'

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case $level in
        INFO)  echo -e "${COLOR_GREEN}[$timestamp] INFO:${COLOR_NC} $message" ;;
        ERROR) echo -e "${COLOR_RED}[$timestamp] ERROR:${COLOR_NC} $message" >&2 ;;
    esac
}

# Example 1: Command with error checking
safe_command() {
    log INFO "Running safe command..."
    
    if ls /tmp &>/dev/null; then
        log INFO "Command succeeded"
        return 0
    else
        log ERROR "Command failed"
        return 1
    fi
}

# Example 2: Variable assignment with fallback
get_value_or_default() {
    local value
    
    # Try to get value, use default if fails
    value=$(cat /nonexistent/file 2>/dev/null || echo "default_value")
    
    log INFO "Value is: $value"
}

# Example 3: Checking optional files
process_optional_file() {
    local file="$1"
    
    if [[ -f "$file" ]]; then
        log INFO "Processing file: $file"
        # Process file...
        return 0
    else
        log INFO "File not found (optional): $file"
        return 0  # Not an error
    fi
}

# Example 4: Required file check
process_required_file() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        log ERROR "Required file missing: $file"
        return 1
    fi
    
    log INFO "Processing required file: $file"
    # Process file...
    return 0
}

# Example 5: Timeout handling
timeout_operation() {
    log INFO "Starting operation with timeout..."
    
    if timeout 5 sleep 2; then
        log INFO "Operation completed within timeout"
    else
        log ERROR "Operation timed out"
        return 1
    fi
}

# Example 6: Retry logic
retry_operation() {
    local max_attempts=3
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        attempt=$((attempt + 1))
        log INFO "Attempt $attempt/$max_attempts"
        
        if ls /tmp &>/dev/null; then
            log INFO "Success on attempt $attempt"
            return 0
        fi
        
        sleep 1
    done
    
    log ERROR "Failed after $max_attempts attempts"
    return 1
}

# Run examples
echo "=== Error Handling Examples ==="
echo ""

safe_command
echo ""

get_value_or_default
echo ""

process_optional_file "/etc/hosts"
process_optional_file "/nonexistent/optional.txt"
echo ""

if process_required_file "/etc/passwd"; then
    log INFO "Required file processed successfully"
fi
echo ""

timeout_operation
echo ""

retry_operation

echo ""
echo "=== All examples completed ==="
