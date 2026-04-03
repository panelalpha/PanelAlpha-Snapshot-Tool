# Testing & Validation Skill

Testing procedures and validation for PanelAlpha Snapshot Tool.

## Overview

This skill covers testing procedures, validation checks, and quality assurance for the pasnap.sh script. Proper testing ensures backups are reliable and restores work correctly.

## Types of Tests

### 1. Syntax Check
Always run before committing changes:

```bash
bash -n pasnap.sh
echo "Syntax OK"
```

### 2. ShellCheck
Static analysis for bash scripts:

```bash
# Install if needed
apt install shellcheck

# Run analysis
shellcheck pasnap.sh

# Ignore specific warnings
shellcheck -e SC1090,SC2001 pasnap.sh
```

### 3. Unit Testing
Test individual functions:

```bash
#!/bin/bash
# test_functions.sh

source pasnap.sh

# Test validate_input
test_validate_input() {
    # Valid snapshot ID
    if validate_input "a1b2c3d4" "snapshot_id"; then
        echo "PASS: valid snapshot ID"
    else
        echo "FAIL: valid snapshot ID rejected"
    fi
    
    # Valid 'latest'
    if validate_input "latest" "snapshot_id"; then
        echo "PASS: 'latest' accepted"
    else
        echo "FAIL: 'latest' rejected"
    fi
    
    # Invalid snapshot ID
    if ! validate_input "invalid!@#" "snapshot_id"; then
        echo "PASS: invalid ID rejected"
    else
        echo "FAIL: invalid ID accepted"
    fi
}

test_validate_input
```

## Integration Testing

### Test Scenarios

#### 1. Fresh Installation Test

```bash
# Clean environment
sudo ./pasnap.sh --install

# Verify dependencies
which restic
which jq
which rsync

# Configure
sudo ./pasnap.sh --setup
# Answer prompts...
```

#### 2. Snapshot Creation Test

```bash
# Create test snapshot
sudo ./pasnap.sh --snapshot

# Verify snapshot created
sudo ./pasnap.sh --list-snapshots

# Check repository
restic -r "$RESTIC_REPOSITORY" snapshots
```

#### 3. Restore Test

```bash
# Restore latest
sudo ./pasnap.sh --restore latest

# Or restore specific
sudo ./pasnap.sh --restore a1b2c3d4

# Verify restoration
# - Check database connectivity
# - Check services running
# - Check file integrity
```

#### 4. Cron Setup Test

```bash
# Install cron
sudo ./pasnap.sh --cron install

# Verify
sudo ./pasnap.sh --cron status
crontab -l | grep pasnap

# Remove
sudo ./pasnap.sh --cron remove
```

## Validation Checks

### Pre-Backup Validation

```bash
validate_pre_backup() {
    log INFO "Running pre-backup validation..."
    
    # Check requirements
    if ! command -v restic &>/dev/null; then
        log ERROR "Restic not installed"
        return 1
    fi
    
    if ! command -v docker &>/dev/null; then
        log ERROR "Docker not installed"
        return 1
    fi
    
    # Check configuration
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log ERROR "Configuration file missing"
        return 1
    fi
    
    # Check disk space
    local available
    available=$(df /tmp | awk 'NR==2 {print $4}')
    if [[ $available -lt 3145728 ]]; then  # 3GB in KB
        log ERROR "Insufficient disk space"
        return 1
    fi
    
    # Test repository connection
    if ! restic -r "$RESTIC_REPOSITORY" snapshots &>/dev/null; then
        log ERROR "Cannot connect to repository"
        return 1
    fi
    
    log INFO "Pre-backup validation passed"
    return 0
}
```

### Post-Backup Validation

```bash
validate_post_backup() {
    local snapshot_id="$1"
    
    log INFO "Validating backup..."
    
    # Check snapshot exists
    if ! restic -r "$RESTIC_REPOSITORY" snapshots "$snapshot_id" &>/dev/null; then
        log ERROR "Snapshot not found"
        return 1
    fi
    
    # Verify snapshot data
    local snapshot_info
    snapshot_info=$(restic -r "$RESTIC_REPOSITORY" snapshots "$snapshot_id" --json 2>/dev/null)
    
    if [[ -z "$snapshot_info" ]]; then
        log ERROR "Cannot retrieve snapshot info"
        return 1
    fi
    
    # Check snapshot size
    local size
    size=$(echo "$snapshot_info" | jq -r '.[0].size')
    if [[ "$size" == "0" || -z "$size" ]]; then
        log WARN "Snapshot size is zero or unknown"
    fi
    
    log INFO "Backup validation passed"
    return 0
}
```

### Database Validation

```bash
validate_database() {
    local container="$1"
    local user="$2"
    local password="$3"
    local database="$4"
    
    # Check connection
    if ! docker exec "$container" mysqladmin -u "$user" -p"$password" ping --silent &>/dev/null; then
        log ERROR "Cannot connect to database"
        return 1
    fi
    
    # Check tables exist
    local table_count
    table_count=$(docker exec "$container" mysql -u "$user" -p"$password" \
        -e "USE $database; SHOW TABLES;" 2>/dev/null | wc -l)
    
    if [[ $table_count -lt 2 ]]; then
        log ERROR "Database appears empty (tables: $((table_count-1)))"
        return 1
    fi
    
    # Check for critical tables
    local critical_tables=("users" "settings" "migrations")
    for table in "${critical_tables[@]}"; do
        if ! docker exec "$container" mysql -u "$user" -p"$password" \
            -e "USE $database; SELECT 1 FROM $table LIMIT 1;" &>/dev/null; then
            log WARN "Critical table missing or empty: $table"
        fi
    done
    
    return 0
}
```

## Test Environment Setup

### Docker Test Environment

```yaml
# docker-compose.test.yml
version: '3.8'
services:
  test-db:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: test
      MYSQL_DATABASE: panelalpha
    volumes:
      - test-db-data:/var/lib/mysql
  
  test-app:
    image: ubuntu:20.04
    command: sleep infinity
    volumes:
      - test-app-data:/data

volumes:
  test-db-data:
  test-app-data:
```

### Test Data Generation

```bash
generate_test_data() {
    # Create test database
    docker exec test-db mysql -u root -ptest -e "
        CREATE DATABASE IF NOT EXISTS test_data;
        USE test_data;
        CREATE TABLE IF NOT EXISTS test_table (
            id INT AUTO_INCREMENT PRIMARY KEY,
            data VARCHAR(255),
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        INSERT INTO test_table (data) VALUES
            ('test1'), ('test2'), ('test3');
    "
    
    # Create test files
    mkdir -p /tmp/test-data
    dd if=/dev/urandom of=/tmp/test-data/random1.bin bs=1M count=10
    dd if=/dev/urandom of=/tmp/test-data/random2.bin bs=1M count=10
    echo "Test content" > /tmp/test-data/test.txt
}
```

## Automated Testing Script

```bash
#!/bin/bash
# run_tests.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSED=0
FAILED=0

run_test() {
    local name="$1"
    local command="$2"
    
    echo -n "Testing $name... "
    if eval "$command" > /tmp/test_output.log 2>&1; then
        echo "PASS"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL"
        FAILED=$((FAILED + 1))
        cat /tmp/test_output.log
    fi
}

# Syntax check
run_test "syntax" "bash -n $SCRIPT_DIR/pasnap.sh"

# Help command
run_test "help" "$SCRIPT_DIR/pasnap.sh --help"

# Version command
run_test "version" "$SCRIPT_DIR/pasnap.sh --version"

# Test configuration exists
run_test "config" "test -f $SCRIPT_DIR/pasnap.sh"

# Summary
echo ""
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
```

## Continuous Integration

### GitHub Actions Example

```yaml
# .github/workflows/test.yml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    
    - name: Syntax Check
      run: bash -n pasnap.sh
    
    - name: ShellCheck
      uses: ludeeus/action-shellcheck@master
      with:
        scandir: '.'
        severity: warning
    
    - name: Setup Test Environment
      run: |
        sudo apt-get update
        sudo apt-get install -y restic jq rsync
    
    - name: Run Unit Tests
      run: |
        chmod +x tests/run_unit_tests.sh
        ./tests/run_unit_tests.sh
```

## Performance Testing

### Backup Speed Test

```bash
benchmark_backup() {
    local test_data_size="${1:-100M}"
    
    # Create test data
    mkdir -p /tmp/benchmark-data
    dd if=/dev/urandom of=/tmp/benchmark-data/test.bin bs="$test_data_size" count=1
    
    # Time the backup
    local start_time
    start_time=$(date +%s)
    
    restic -r /tmp/test-repo backup /tmp/benchmark-data --json
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo "Backup of $test_data_size took ${duration}s"
    
    # Cleanup
    rm -rf /tmp/benchmark-data /tmp/test-repo
}
```

## Regression Testing

### Common Regression Checks

1. **Environment File Handling**
   - Test with `.env` only
   - Test with `.env-core` only
   - Test with both files

2. **Docker Compose Detection**
   - Test with legacy `docker-compose`
   - Test with modern `docker compose`

3. **Database Types**
   - Test Engine mode (core + users DB)
   - Test Control Panel mode (API DB)

4. **Storage Backends**
   - Local
   - SFTP
   - S3

## Test Checklist

Before releasing:

- [ ] Syntax check passes (`bash -n`)
- [ ] ShellCheck passes with no errors
- [ ] Help text displays correctly
- [ ] Version command works
- [ ] Fresh install test passes
- [ ] Snapshot creation works
- [ ] Snapshot restore works
- [ ] Database restore validates
- [ ] Cron install/remove works
- [ ] All storage backends tested (if possible)
- [ ] Error handling works
- [ ] Logging works correctly

## Debugging Failed Tests

### Enable Debug Mode

```bash
# Set debug environment variable
export PASNAP_DEBUG=1

# Run with debug output
sudo bash -x ./pasnap.sh --snapshot 2>&1 | tee debug.log
```

### Check Logs

```bash
# View recent logs
tail -100 /var/log/pasnap.log

# Follow logs
tail -f /var/log/pasnap.log
```

### Verbose Mode

```bash
# Run restic with verbose output
restic backup /path --verbose 2>&1
```
