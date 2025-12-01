# Configuration Reference

Complete reference for all configuration options.

## Configuration File

Configuration is stored in `/opt/panelalpha/app/.env-backup` (Control Panel) or `/opt/panelalpha/engine/.env-backup` (Engine).

## Repository Settings

### RESTIC_REPOSITORY

The storage backend location.

```bash
# Local storage
RESTIC_REPOSITORY="/backup/pasnap-snapshots"

# SFTP storage
RESTIC_REPOSITORY="sftp:user@hostname:/path/to/backups"

# S3 storage
RESTIC_REPOSITORY="s3:s3.eu-west-1.amazonaws.com/bucket/path"
```

### RESTIC_PASSWORD

Encryption password for all snapshots. **Required**.

```bash
RESTIC_PASSWORD="your-secure-encryption-password"
```

> ⚠️ **Important**: Store this password securely. Without it, you cannot restore your snapshots.

---

## S3 Credentials

Required only for S3-compatible storage backends.

### AWS_ACCESS_KEY_ID

```bash
AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
```

### AWS_SECRET_ACCESS_KEY

```bash
AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
```

---

## Snapshot Settings

### BACKUP_RETENTION_DAYS

Number of days to keep snapshots before automatic cleanup.

```bash
BACKUP_RETENTION_DAYS=30
```

Default: `30`

### BACKUP_HOUR

Hour of day (0-23) when automatic backups run.

```bash
BACKUP_HOUR=2
```

Default: `2` (2:00 AM)

### BACKUP_TAG_PREFIX

Prefix for snapshot tags to identify backups.

```bash
BACKUP_TAG_PREFIX="panelalpha"
```

Default: `panelalpha`

---

## System Paths

### LOG_FILE

Location of the log file.

```bash
LOG_FILE="/var/log/pasnap.log"
```

Default: `/var/log/pasnap.log`

### BACKUP_TEMP_DIR

Temporary directory for backup operations.

```bash
BACKUP_TEMP_DIR="/var/tmp"
```

Default: `/var/tmp`

### RESTIC_CACHE_DIR

Cache directory for restic.

```bash
RESTIC_CACHE_DIR="/var/cache/restic"
```

Default: `/var/cache/restic`

---

## Complete Example

### Local Storage

```bash
RESTIC_REPOSITORY="/backup/pasnap-snapshots"
RESTIC_PASSWORD="my-secure-password-123"

BACKUP_RETENTION_DAYS=30
BACKUP_HOUR=2
BACKUP_TAG_PREFIX="panelalpha"

LOG_FILE="/var/log/pasnap.log"
BACKUP_TEMP_DIR="/var/tmp"
RESTIC_CACHE_DIR="/var/cache/restic"
```

### S3 Storage (AWS)

```bash
RESTIC_REPOSITORY="s3:s3.eu-west-1.amazonaws.com/my-bucket/pasnap-snapshots"
RESTIC_PASSWORD="my-secure-password-123"

AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

BACKUP_RETENTION_DAYS=30
BACKUP_HOUR=2
BACKUP_TAG_PREFIX="panelalpha"

LOG_FILE="/var/log/pasnap.log"
BACKUP_TEMP_DIR="/var/tmp"
RESTIC_CACHE_DIR="/var/cache/restic"
```

### SFTP Storage

```bash
RESTIC_REPOSITORY="sftp:backup-user@backup.example.com:/backups/panelalpha"
RESTIC_PASSWORD="my-secure-password-123"

BACKUP_RETENTION_DAYS=30
BACKUP_HOUR=2
BACKUP_TAG_PREFIX="panelalpha"

LOG_FILE="/var/log/pasnap.log"
BACKUP_TEMP_DIR="/var/tmp"
RESTIC_CACHE_DIR="/var/cache/restic"
```

---

## Security Notes

- Configuration file permissions are set to `600` (owner read/write only)
- S3 credentials are only exported during backup/restore operations
- All snapshots are encrypted with AES-256
- The encryption password is never transmitted over the network
