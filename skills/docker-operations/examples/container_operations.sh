#!/bin/bash
# Example: Docker Operations
# Demonstrates common Docker patterns used in pasnap.sh

# Example 1: Get container ID safely
get_container_id() {
    local service_name="$1"
    local container_id
    
    # Try modern syntax first, fallback to legacy
    container_id=$(docker compose ps -q "$service_name" 2>/dev/null || \
                   docker-compose ps -q "$service_name" 2>/dev/null)
    
    if [[ -z "$container_id" ]]; then
        echo "ERROR: Container for $service_name not found"
        return 1
    fi
    
    echo "$container_id"
}

# Example 2: Check if container is running
is_container_running() {
    local container="$1"
    
    if docker ps --quiet --filter "id=$container" | grep -q .; then
        return 0
    fi
    return 1
}

# Example 3: Execute MySQL command
mysql_exec() {
    local container="$1"
    local user="$2"
    local password="$3"
    local command="$4"
    
    # Use environment variable for password (more secure)
    docker exec -e MYSQL_PWD="$password" "$container" \
        mysql -u "$user" -e "$command" 2>/dev/null
}

# Example 4: Backup volume to tar.gz
backup_volume() {
    local volume_name="$1"
    local backup_path="$2"
    
    echo "Backing up volume: $volume_name"
    
    docker run --rm \
        -v "${volume_name}":/source:ro \
        -v "$(dirname "$backup_path")":/backup \
        alpine:latest \
        tar czf "/backup/$(basename "$backup_path")" -C /source . 2>/dev/null
    
    if [[ -f "$backup_path" ]]; then
        echo "Backup created: $backup_path"
        ls -lh "$backup_path"
        return 0
    else
        echo "ERROR: Backup failed"
        return 1
    fi
}

# Example 5: Restore volume from tar.gz
restore_volume() {
    local volume_name="$1"
    local backup_path="$2"
    
    echo "Restoring volume: $volume_name from $backup_path"
    
    # Create volume if not exists
    docker volume create "$volume_name" 2>/dev/null || true
    
    docker run --rm \
        -v "${volume_name}":/target \
        -v "$(dirname "$backup_path")":/backup:ro \
        alpine:latest \
        tar xzf "/backup/$(basename "$backup_path")" -C /target 2>/dev/null
    
    echo "Restore completed"
}

# Example 6: Wait for MySQL to be ready
wait_for_mysql() {
    local container="$1"
    local max_attempts=30
    local attempt=0
    
    echo "Waiting for MySQL in container: $container"
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker exec "$container" mysqladmin ping --silent 2>/dev/null; then
            echo "MySQL is ready!"
            return 0
        fi
        
        attempt=$((attempt + 1))
        echo "Attempt $attempt/$max_attempts - MySQL not ready yet..."
        sleep 2
    done
    
    echo "ERROR: MySQL failed to become ready"
    return 1
}

# Example 7: List volumes for a project
list_project_volumes() {
    local project_name="$1"
    
    echo "Volumes for project: $project_name"
    docker volume ls --filter "name=${project_name}_" --format "{{.Name}}"
}

# Main demonstration
echo "=== Docker Operations Examples ==="
echo ""
echo "Note: These examples show code patterns."
echo "They won't run without Docker running."
echo ""

echo "Example 1: Get Container ID"
echo "  get_container_id 'database-core'"
echo ""

echo "Example 2: Check Container Status"
echo "  if is_container_running '\$container'; then"
echo "    echo 'Running'"
echo "  fi"
echo ""

echo "Example 3: MySQL Operations"
echo "  mysql_exec '\$container' 'core' '\$password' 'SELECT 1;'"
echo ""

echo "Example 4: Volume Backup"
echo "  backup_volume 'myproject_data' '/backup/data.tar.gz'"
echo ""

echo "Example 5: Volume Restore"
echo "  restore_volume 'myproject_data' '/backup/data.tar.gz'"
echo ""

echo "Example 6: Wait for Service"
echo "  wait_for_mysql '\$container_id'"
echo ""

echo "Example 7: List Volumes"
echo "  list_project_volumes 'panelalpha'"
echo ""

echo "=== End of Examples ==="
