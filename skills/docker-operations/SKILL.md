# Docker Operations Skill

Docker and Docker Compose operations for the PanelAlpha Snapshot Tool.

## Overview

This skill covers Docker container operations used for backing up and restoring PanelAlpha installations. The script supports both `docker-compose` (legacy) and `docker compose` (modern) syntax.

## Container Detection

### Get Container ID

```bash
# Modern syntax (preferred)
container=$(docker compose ps -q service_name 2>/dev/null)

# Legacy syntax
container=$(docker-compose ps -q service_name 2>/dev/null)

# Check if container exists
if [[ -z "$container" ]]; then
    log ERROR "Container not found"
    return 1
fi
```

### Check Container Status

```bash
# Check if running
if docker ps --quiet --filter "id=$container" | grep -q .; then
    log INFO "Container is running"
fi

# Get health status
docker inspect --format='{{.State.Health.Status}}' "$container"

# Get exit code
docker inspect --format='{{.State.ExitCode}}' "$container"
```

## Container Operations

### Execute Commands

```bash
# Simple command
docker exec "$container" command args

# With input from file
docker exec -i "$container" mysql < dump.sql

# Interactive with TTY
docker exec -it "$container" bash

# With environment variable
docker exec -e VAR=value "$container" command
```

### Copy Operations

```bash
# Copy from container to host
docker cp "$container:/path/in/container" /host/path

# Copy from host to container
docker cp /host/path "$container:/path/in/container"

# Copy between containers
docker cp "$container1:/path" - | docker cp - "$container2:/path"
```

## Volume Operations

### Volume Backup (Tar)

```bash
backup_volume() {
    local volume_name="$1"
    local backup_file="$2"
    
    docker run --rm \
        -v "${volume_name}":/source:ro \
        -v "$(dirname $backup_file)":/backup \
        ubuntu:20.04 \
        tar czf "/backup/$(basename $backup_file)" -C /source .
}
```

### Volume Restore (Tar)

```bash
restore_volume() {
    local volume_name="$1"
    local backup_file="$2"
    
    # Create volume if not exists
    docker volume create "$volume_name" 2>/dev/null || true
    
    docker run --rm \
        -v "${volume_name}":/target \
        -v "$(dirname $backup_file)":/backup:ro \
        ubuntu:20.04 \
        tar xzf "/backup/$(basename $backup_file)" -C /target
}
```

### List Volume Contents

```bash
docker run --rm -v "${volume_name}":/vol alpine ls -la /vol
```

## Docker Compose Operations

### Service Management

```bash
# Start services
docker compose up -d service_name
docker compose up -d  # all services

# Stop services
docker compose stop service_name
docker compose down    # stop and remove

# Restart services
docker compose restart service_name

# View logs
docker compose logs service_name
docker compose logs --tail=100 -f service_name  # follow
```

### Service Information

```bash
# List running containers
docker compose ps

# Get container IDs
docker compose ps -q service_name

# Check config
docker compose config
```

## Database Containers

### Engine Installation

```bash
# Core database
docker compose ps -q database-core
docker exec "$core_container" mysql -u core -p"$password" -e "SELECT 1;"

# Users database
docker compose ps -q database-users
docker exec "$users_container" mysql -u root -p"$password" -e "SELECT 1;"
```

### Control Panel Installation

```bash
# API database
docker compose ps -q database-api
docker exec "$api_container" mysql -u panelalpha -p"$password" -e "SELECT 1;"
```

### MySQL Operations

```bash
# Check if MySQL is ready
docker exec "$container" mysqladmin ping --silent

# Create dump
docker exec "$container" mysqldump -u user -p"$pass" database > dump.sql

# Import dump
docker exec -i "$container" mysql -u user -p"$pass" database < dump.sql

# Execute SQL
docker exec "$container" mysql -u user -p"$pass" -e "SQL_COMMAND;"
```

## Best Practices

### 1. Always Check Container Exists

```bash
get_container() {
    local service="$1"
    local container
    
    container=$(docker compose ps -q "$service" 2>/dev/null)
    
    if [[ -z "$container" ]]; then
        log ERROR "Container for $service not found"
        return 1
    fi
    
    echo "$container"
}
```

### 2. Handle Both Docker Compose Versions

```bash
# Define helper function
docker_compose() {
    if command -v docker-compose &>/dev/null; then
        docker-compose "$@"
    else
        docker compose "$@"
    fi
}

# Use helper
docker_compose ps -q service
```

### 3. Timeout Operations

```bash
# Use timeout for long operations
timeout 300 docker exec "$container" mysqldump ... > dump.sql

# Check exit code
if [[ $? -eq 124 ]]; then
    log ERROR "Operation timed out"
fi
```

### 4. Error Handling

```bash
# Check docker daemon
if ! docker info &>/dev/null; then
    log ERROR "Docker daemon is not running"
    exit 1
fi

# Handle docker errors gracefully
if ! docker exec "$container" command; then
    log ERROR "Command failed in container"
    return 1
fi
```

## Common Patterns

### Wait for Container Ready

```bash
wait_for_container() {
    local container="$1"
    local max_attempts="${2:-30}"
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if docker exec "$container" mysqladmin ping --silent &>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    
    return 1
}
```

### Run One-Off Container

```bash
# For operations requiring tools not in main containers
docker run --rm \
    --volumes-from "$container" \
    -v "$backup_dir":/backup \
    alpine:latest \
    tar czf /backup/data.tar.gz /data
```

## Troubleshooting

### Container Not Found

```bash
# Check if service exists
docker compose config --services | grep service_name

# Check for typos in service name
# Check docker-compose.yml syntax
docker compose config
```

### Permission Denied

```bash
# Run as root (script already requires root)
# Check container user
docker exec "$container" id

# Use appropriate user
docker exec --user root "$container" command
```

### Volume Mount Issues

```bash
# Check volume exists
docker volume inspect volume_name

# Check volume path
docker volume inspect --format='{{.Mountpoint}}' volume_name

# List volumes
docker volume ls
```
