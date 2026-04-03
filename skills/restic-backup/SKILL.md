# Restic Backup Skill

Restic backup operations for PanelAlpha Snapshot Tool.

## Overview

This skill covers Restic operations for creating, managing, and restoring backups. Restic is a modern backup program that supports encryption, deduplication, and multiple storage backends.

## Supported Backends

| Backend | URL Format | Use Case |
|---------|------------|----------|
| Local | `/path/to/repo` | Development, single server |
| SFTP | `sftp:user@host:/path` | Remote server backup |
| S3 | `s3:s3.amazonaws.com/bucket` | AWS S3, compatible services |
| MinIO | `s3:host/bucket` | Self-hosted S3 |

## Repository Initialization

### Check if Repository Exists

```bash
if restic -r "$RESTIC_REPOSITORY" snapshots &>/dev/null; then
    log INFO "Repository exists"
else
    log INFO "Repository not initialized"
fi
```

### Initialize Repository

```bash
init_repository() {
    local repo="$1"
    local password="$2"
    
    export RESTIC_PASSWORD="$password"
    
    if restic -r "$repo" init 2>/dev/null; then
        log INFO "Repository initialized"
    else
        log ERROR "Failed to initialize repository"
        return 1
    fi
}
```

## Creating Backups

### Basic Backup

```bash
create_backup() {
    local source="$1"
    local tag="$2"
    
    restic -r "$RESTIC_REPOSITORY" backup "$source" \
        --tag "$tag" \
        --verbose \
        --json
}
```

### Backup with Multiple Tags

```bash
restic backup "$source" \
    --tag "panelalpha" \
    --tag "$(hostname)" \
    --tag "databases" \
    --tag "volumes" \
    --tag "config"
```

### Exclude Patterns

```bash
restic backup "$source" \
    --exclude="*.log" \
    --exclude="cache/*" \
    --exclude-file=/path/to/exclude-list
```

## Managing Snapshots

### List Snapshots

```bash
# All snapshots
restic -r "$RESTIC_REPOSITORY" snapshots

# By tag
restic -r "$RESTIC_REPOSITORY" snapshots --tag "panelalpha"

# Compact view
restic -r "$RESTIC_REPOSITORY" snapshots --compact

# JSON output for scripting
restic -r "$RESTIC_REPOSITORY" snapshots --json | jq
```

### Get Latest Snapshot ID

```bash
get_latest_snapshot() {
    local tag="$1"
    
    restic -r "$RESTIC_REPOSITORY" snapshots \
        --tag "$tag" \
        --json 2>/dev/null | \
        jq -r 'if length > 0 then .[0].short_id else empty end'
}
```

### Delete Snapshots

```bash
# Delete specific snapshot
restic -r "$RESTIC_REPOSITORY" forget "$snapshot_id" --prune

# Delete by policy
restic -r "$RESTIC_REPOSITORY" forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 12 \
    --prune
```

## Restoring Data

### Restore Latest Snapshot

```bash
restore_latest() {
    local target="$1"
    local tag="$2"
    
    restic -r "$RESTIC_REPOSITORY" restore latest \
        --tag "$tag" \
        --target "$target"
}
```

### Restore Specific Snapshot

```bash
restic -r "$RESTIC_REPOSITORY" restore "$snapshot_id" \
    --target "$target_dir" \
    --include="/path/in/snapshot"
```

### Restore Specific Files

```bash
restic -r "$RESTIC_REPOSITORY" restore "$snapshot_id" \
    --target "$target_dir" \
    --include="/path/to/file" \
    --include="/path/to/another/file"
```

## Repository Maintenance

### Check Repository

```bash
# Full check
restic -r "$RESTIC_REPOSITORY" check

# Read data
restic -r "$RESTIC_REPOSITORY" check --read-data

# With percentage
restic -r "$RESTIC_REPOSITORY" check --read-data-subset=10%
```

### Prune Repository

```bash
# Remove unreferenced data
restic -r "$RESTIC_REPOSITORY" prune

# With specific policy
restic -r "$RESTIC_REPOSITORY" forget --prune \
    --keep-last 10 \
    --keep-daily 7
```

### Repository Stats

```bash
# Quick stats
restic -r "$RESTIC_REPOSITORY" stats

# Mode details
restic -r "$RESTIC_REPOSITORY" stats --mode=raw-data

# Snapshots size
restic -r "$RESTIC_REPOSITORY" stats --tag "panelalpha"
```

## Mount Repository

```bash
# Mount for browsing
mkdir -p /mnt/restic
restic -r "$RESTIC_REPOSITORY" mount /mnt/restic

# Access snapshots at /mnt/restic/snapshots/
# Unmount when done
umount /mnt/restic
```

## Environment Configuration

### Required Variables

```bash
export RESTIC_REPOSITORY="/backup/panelalpha"
export RESTIC_PASSWORD="your-secure-password"
```

### S3 Configuration

```bash
export RESTIC_REPOSITORY="s3:s3.amazonaws.com/mybucket/panelalpha"
export RESTIC_PASSWORD="encryption-password"
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"

# For non-AWS S3 (MinIO, etc.)
export RESTIC_REPOSITORY="s3:minio.example.com/mybucket/panelalpha"
```

### SFTP Configuration

```bash
export RESTIC_REPOSITORY="sftp:backup@backup-server:/backups/panelalpha"
export RESTIC_PASSWORD="encryption-password"

# SSH key authentication must be configured
```

## Best Practices

### 1. Use Consistent Tags

```bash
BACKUP_TAG="panelalpha-$(hostname)"
```

### 2. Implement Retry Logic

```bash
backup_with_retry() {
    local max_attempts=3
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if restic backup "$source" --tag "$tag"; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    
    return 1
}
```

### 3. Verify Backups

```bash
verify_backup() {
    local snapshot_id="$1"
    
    if restic check --with-restic-id "$snapshot_id"; then
        log INFO "Backup verified"
        return 0
    else
        log ERROR "Backup verification failed"
        return 1
    fi
}
```

### 4. Set Retention Policy

```bash
apply_retention() {
    local days="${1:-30}"
    
    restic forget \
        --tag "$BACKUP_TAG" \
        --keep-daily "$days" \
        --prune
}
```

## Error Handling

### Common Errors

```bash
# Repository not found
if ! restic snapshots &>/dev/null; then
    log ERROR "Repository not accessible"
    exit 1
fi

# Wrong password
if ! restic snapshots 2>/dev/null; then
    log ERROR "Invalid repository password"
    exit 1
fi

# Network issues
if ! restic snapshots 2>&1 | grep -q "timeout"; then
    log WARN "Network timeout - retrying..."
fi
```

## Performance Optimization

### 1. Use Cache

```bash
export RESTIC_CACHE_DIR="/var/cache/restic"
```

### 2. Limit Bandwidth

```bash
restic backup --limit-upload 10000  # 10 MB/s
```

### 3. Parallel Operations

```bash
# Set GOMAXPROCS for more parallelism
export GOMAXPROCS=4
```

## Security

### 1. Strong Passwords

- Minimum 12 characters
- Mix of uppercase, lowercase, numbers, symbols
- Store securely (not in scripts)

### 2. Key Management

```bash
# For S3, use IAM roles when possible
# For SFTP, use SSH keys with limited access
```

### 3. Repository Permissions

```bash
# Local repository
chmod 700 "$RESTIC_REPOSITORY"
```

## Troubleshooting

### Slow Backup

- Check network speed
- Use `--limit-upload` to prevent saturation
- Exclude large unnecessary files

### High Memory Usage

- Reduce `GOMAXPROCS`
- Backup in smaller chunks
- Use `--read-concurrency 1`

### Repository Lock

```bash
# Check for locks
restic list locks

# Remove stale lock (be careful!)
restic unlock
```
