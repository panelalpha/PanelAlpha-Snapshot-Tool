# Database Management Skill

MySQL/MariaDB operations for PanelAlpha Snapshot Tool.

## Overview

This skill covers database operations for backing up and restoring MySQL/MariaDB databases used by PanelAlpha. The tool handles different database configurations for Engine vs Control Panel installations.

## Database Types

### PanelAlpha Engine

| Service | Container | User | Purpose |
|---------|-----------|------|---------|
| Core DB | database-core | core | PanelAlpha core data |
| Users DB | database-users | root | Customer databases |

### PanelAlpha Control Panel

| Service | Container | User | Purpose |
|---------|-----------|------|---------|
| API DB | database-api | panelalpha | Control panel data |

## Password Extraction

### From Environment Files

```bash
# Engine - Core database
core_password=$(grep "^CORE_MYSQL_PASSWORD=" "$ENV_FILE" | head -1 | cut -d'=' -f2- | tr -d '"')

# Engine - Users database
users_password=$(grep "^USERS_MYSQL_ROOT_PASSWORD=" "$ENV_FILE" | head -1 | cut -d'=' -f2- | tr -d '"')

# Control Panel - API database
api_password=$(grep "^API_MYSQL_PASSWORD=" "$ENV_FILE" | head -1 | cut -d'=' -f2- | tr -d '"')
```

### From Running Container

```bash
# Get from container environment
root_password=$(docker exec "$container" printenv MYSQL_ROOT_PASSWORD 2>/dev/null)
mariadb_root=$(docker exec "$container" printenv MARIADB_ROOT_PASSWORD 2>/dev/null)
```

## Secure MySQL Execution

### Using Temporary Config File

```bash
secure_mysql_exec() {
    local container="$1"
    local username="$2"
    local password="$3"
    local database="$4"
    local sql_command="$5"
    
    # Create temporary config
    local temp_config
    temp_config=$(mktemp)
    chmod 600 "$temp_config"
    
    cat > "$temp_config" << EOF
[client]
user=$username
password=$password
EOF
    
    # Execute with timeout
    local result=0
    if timeout 30 docker exec -i "$container" \
        mysql --defaults-file=<(cat "$temp_config") "$database" <<< "$sql_command" 2>/dev/null; then
        result=0
    else
        result=1
    fi
    
    # Cleanup
    rm -f "$temp_config"
    return $result
}
```

### Never Log Passwords

```bash
# WRONG - password visible in logs
docker exec "$container" mysql -u user -p"$password" -e "SELECT 1;"

# CORRECT - password via environment
docker exec -e MYSQL_PWD="$password" "$container" mysql -u user -e "SELECT 1;"
```

## Database Backup

### Single Database Dump

```bash
dump_database() {
    local container="$1"
    local user="$2"
    local password="$3"
    local database="$4"
    local output_file="$5"
    
    timeout 600 docker exec "$container" \
        mysqldump -u "$user" -p"$password" "$database" \
        --single-transaction \
        --routines \
        --triggers \
        --lock-tables=false \
        --add-drop-database \
        --create-options \
        --disable-keys \
        --extended-insert \
        --quick \
        --set-charset \
        > "$output_file" 2>/dev/null
}
```

### All Databases Dump

```bash
dump_all_databases() {
    local container="$1"
    local user="$2"
    local password="$3"
    local output_file="$4"
    
    local -a mysqldump_args=(
        mysqldump
        -u "$user"
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
    
    timeout 1800 docker exec -e MYSQL_PWD="$password" "$container" \
        "${mysqldump_args[@]}" > "$output_file" 2>/dev/null
}
```

### Compressed Dump

```bash
dump_compressed() {
    local container="$1"
    local user="$2"
    local password="$3"
    local output_file="$4"
    
    timeout 1800 docker exec -e MYSQL_PWD="$password" "$container" \
        sh -c "mysqldump -u $user --all-databases 2>/dev/null | gzip -c -1" \
        > "$output_file"
}
```

## Database Restore

### Drop and Recreate Database

```bash
recreate_database() {
    local container="$1"
    local user="$2"
    local password="$3"
    local database="$4"
    
    docker exec "$container" mysql -u "$user" -p"$password" -e "
        DROP DATABASE IF EXISTS $database;
        CREATE DATABASE $database CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    " 2>/dev/null
}
```

### Import SQL File

```bash
import_database() {
    local container="$1"
    local user="$2"
    local password="$3"
    local database="$4"
    local sql_file="$5"
    
    if [[ ! -f "$sql_file" ]]; then
        log ERROR "SQL file not found: $sql_file"
        return 1
    fi
    
    if [[ "$sql_file" == *.gz ]]; then
        # Compressed file
        gunzip -c "$sql_file" | docker exec -i "$container" \
            mysql -u "$user" -p"$password" "$database" 2>/dev/null
    else
        # Uncompressed file
        docker exec -i "$container" mysql -u "$user" -p"$password" \
            "$database" < "$sql_file" 2>/dev/null
    fi
}
```

## User Management

### Create Database User

```bash
create_db_user() {
    local container="$1"
    local username="$2"
    local password="$3"
    local root_password="$4"
    
    docker exec "$container" mysql -u root -p"$root_password" -e "
        CREATE USER IF NOT EXISTS '$username'@'%' IDENTIFIED BY '$password';
        CREATE USER IF NOT EXISTS '$username'@'localhost' IDENTIFIED BY '$password';
        GRANT ALL PRIVILEGES ON $username.* TO '$username'@'%';
        GRANT ALL PRIVILEGES ON $username.* TO '$username'@'localhost';
        FLUSH PRIVILEGES;
    " 2>/dev/null
}
```

### Verify User Exists

```bash
verify_user() {
    local container="$1"
    local username="$2"
    local password="$3"
    
    if docker exec "$container" mysql -u "$username" -p"$password" \
        -e "SELECT 1;" 2>/dev/null >/dev/null; then
        return 0
    fi
    return 1
}
```

## Database Verification

### Check Table Count

```bash
get_table_count() {
    local container="$1"
    local user="$2"
    local password="$3"
    local database="$4"
    
    docker exec "$container" mysql -u "$user" -p"$password" \
        -e "USE $database; SHOW TABLES;" 2>/dev/null | wc -l
}
```

### Check Database Size

```bash
get_db_size() {
    local container="$1"
    local user="$2"
    local password="$3"
    local database="$4"
    
    docker exec "$container" mysql -u "$user" -p"$password" \
        -e "SELECT SUM(data_length + index_length) FROM information_schema.tables \
        WHERE table_schema = '$database';" 2>/dev/null
}
```

### Verify Database Integrity

```bash
verify_database() {
    local container="$1"
    local user="$2"
    local password="$3"
    local database="$4"
    
    log INFO "Checking database integrity..."
    
    # Check connection
    if ! docker exec "$container" mysqladmin -u "$user" -p"$password" ping --silent 2>/dev/null; then
        log ERROR "Cannot connect to database"
        return 1
    fi
    
    # Check tables
    local tables
    tables=$(docker exec "$container" mysql -u "$user" -p"$password" \
        -e "USE $database; SHOW TABLES;" 2>/dev/null)
    
    if [[ -z "$tables" ]]; then
        log WARN "No tables found in database"
        return 1
    fi
    
    log INFO "Database verification passed"
    return 0
}
```

## Best Practices

### 1. Always Use Timeouts

```bash
timeout 600 docker exec ... mysqldump ...
```

### 2. Check File Integrity

```bash
verify_dump() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        log ERROR "Dump file does not exist"
        return 1
    fi
    
    local size
    size=$(stat -c%s "$file" 2>/dev/null || echo "0")
    
    if [[ $size -lt 100 ]]; then
        log ERROR "Dump file is too small ($size bytes)"
        return 1
    fi
    
    # Check for SQL content
    if ! head -1 "$file" | grep -q "SQL" 2>/dev/null; then
        log WARN "Dump file may be corrupted"
    fi
}
```

### 3. Handle Connection Failures

```bash
# Test connection before operations
if ! docker exec "$container" mysqladmin ping --silent 2>/dev/null; then
    log ERROR "Database not ready"
    return 1
fi
```

### 4. Use Transactions

```bash
mysqldump ... --single-transaction ...
```

## Common Issues

### Connection Refused

- Container not running
- Wrong port/host
- Network issues

### Access Denied

- Wrong password
- User doesn't exist
- Insufficient privileges

### Lock Wait Timeout

- Long-running queries
- Use `--lock-tables=false` with `--single-transaction`

### Out of Memory

- Reduce `--max-allowed-packet`
- Use compression
- Stream directly to destination
