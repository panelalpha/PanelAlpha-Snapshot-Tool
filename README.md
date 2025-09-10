# 📸 PanelAlpha - Snapshot Tool

Professional tool for creating secure backups (snapshots) of PanelAlpha applications.

## 🎯 What is this?

This tool allows you to:
- **Create complete backups** of PanelAlpha (databases, files, configuration)
- **Automatically create backups** at scheduled times
- **Restore the system** on the same or new server
- **Securely store** backups in the cloud or locally

## 🚀 Quick Start

### Step 1: Installation

Run in terminal on the server with PanelAlpha:

```bash
sudo ./panelalpha-snapshot.sh --install
```

This will install all necessary tools.

### Step 2: Configuration

Configure backup storage location:

```bash
sudo ./panelalpha-snapshot.sh --setup
```

The program will guide you through simple step-by-step configuration.

### Step 3: Test

Check if everything works:

```bash
sudo ./panelalpha-snapshot.sh --test-connection
```

### Step 4: First backup

Create your first backup:

```bash
sudo ./panelalpha-snapshot.sh --snapshot
```

### Step 5: Automation (optional)

Configure automatic backup creation:

```bash
sudo ./panelalpha-snapshot.sh --cron install
```

## 📁 Where to store backups?

### 💾 Local storage
- **Easiest** - backups on the same server
- **Warning**: If the server breaks, you will lose backups
- **Example**: `/backup/panelalpha`

### 🌐 Cloud storage (S3)
- **Safest** - backups in the cloud
- **Supports**: AWS S3, Hetzner Storage, DigitalOcean Spaces
- **Requires**: cloud service account

### 🔗 Remote server (SFTP)
- **Moderately safe** - backups on another server
- **Requires**: SSH access to another server

## 🔧 Basic Commands

```bash
# Create backup
sudo ./panelalpha-snapshot.sh --snapshot

# View available backups
sudo ./panelalpha-snapshot.sh --list-snapshots

# Restore from latest backup
sudo ./panelalpha-snapshot.sh --restore latest

# Restore from specific backup (replace a1b2c3d4 with actual ID)
sudo ./panelalpha-snapshot.sh --restore a1b2c3d4

# Delete old backup
sudo ./panelalpha-snapshot.sh --delete-snapshots a1b2c3d4

# Check automatic backup status
sudo ./panelalpha-snapshot.sh --cron status
```

## 🏠 Restoring on the same server

If you have problems with PanelAlpha and want to restore a previous state:

1. **View available backups**:
   ```bash
   sudo ./panelalpha-snapshot.sh --list-snapshots
   ```

2. **Restore from selected backup**:
   ```bash
   sudo ./panelalpha-snapshot.sh --restore a1b2c3d4
   ```

3. **Or restore the latest backup**:
   ```bash
   sudo ./panelalpha-snapshot.sh --restore latest
   ```

⚠️ **WARNING**: Restoration will replace all current data!

## 🚛 Migration to new server

Moving PanelAlpha to a new server:

### On the old server:
1. **Create backup**:
   ```bash
   sudo ./panelalpha-snapshot.sh --snapshot
   ```

2. **Save backup ID** from command output

### On the new server:
1. **Install PanelAlpha** (basic installation)

2. **Copy snapshot tool** and install:
   ```bash
   sudo ./panelalpha-snapshot.sh --install
   ```

3. **Configure** (use the same settings as on the old server):
   ```bash
   sudo ./panelalpha-snapshot.sh --setup
   ```

4. **Restore backup**:
   ```bash
   sudo ./panelalpha-snapshot.sh --restore a1b2c3d4
   ```

## 🤖 Automatic backups

### Enable automation:
```bash
sudo ./panelalpha-snapshot.sh --cron install
```

### Check status:
```bash
sudo ./panelalpha-snapshot.sh --cron status
```

### Disable automation:
```bash
sudo ./panelalpha-snapshot.sh --cron remove
```

## 📊 What is saved in backup?

### 🗄️ Databases
- All PanelAlpha data (users, servers, domains)
- Matomo statistics

### 📂 Application files
- Docker configuration
- Custom extensions
- SSL certificates
- nginx settings

### 💾 Application data
- User files
- Cache and sessions
- All Docker volumes

## ❓ Common Problems

### 🔐 "Permission denied"
```bash
# Always run with sudo
sudo ./panelalpha-snapshot.sh --snapshot
```

### 🐳 "Docker not working"
```bash
# Start Docker
sudo systemctl start docker
sudo systemctl enable docker
```

### 🌐 "Cannot connect to repository"
```bash
# Check configuration
sudo ./panelalpha-snapshot.sh --test-connection

# Edit configuration if needed
sudo nano /opt/panelalpha/app/.env-backup
```

### 💾 "No disk space"
```bash
# Check free space
df -h

# Delete old backups
sudo ./panelalpha-snapshot.sh --delete-snapshots old-snapshot-id
```

### 🔍 "Database error"
1. Check if PanelAlpha is running: `docker compose ps`
2. Check passwords in `.env` file
3. Check logs: `sudo tail -f /var/log/panelalpha-snapshot.log`

## 📋 System Requirements

- **System**: Ubuntu 18.04+ or compatible Linux
- **Docker**: Version 20.10+
- **Space**: At least 3GB free space
- **Internet**: For uploading backups to cloud
- **Permissions**: Root access (sudo)

## 📝 Logs and Monitoring

### Check logs:
```bash
# Recent operations
sudo tail -f /var/log/panelalpha-snapshot.log

# Search for errors
sudo grep ERROR /var/log/panelalpha-snapshot.log
```

### Check automatic backup activity:
```bash
sudo ./panelalpha-snapshot.sh --cron status
```

## 🆘 Help

If you have problems:

1. **Check logs** for errors
2. **Verify system requirements**
3. **Run connection test**: `sudo ./panelalpha-snapshot.sh --test-connection`
4. **Contact your system administrator**

## 🔐 Security

- ✅ All backups are **encrypted**
- ✅ Passwords are **securely stored**
- ✅ Communication through **encrypted connections**
- ✅ Configuration files have **restricted permissions**

---

💡 **Tip**: Always test backup restoration on a test environment before using in production!

## What Gets Captured

### Databases
- **PanelAlpha API Database**: Complete MySQL dump with routines and triggers

### Docker Volumes
- `api-storage`: PanelAlpha application data
- `database-api-data`: MySQL data files
- `redis-data`: Redis cache and session data

### Configuration Files
- `docker-compose.yml`: Container orchestration configuration
- `.env` files: Environment variables and secrets
- `packages/`: Custom packages and extensions
- SSL certificates: Let's Encrypt certificates
- Nginx configurations: Web server settings

## Storage Backends

### Local Storage
```bash
Repository type: local
Example: /backup/panelalpha-snapshots
```
- Best for: Development, testing, local backups
- Pros: Fast, simple setup
- Cons: Single point of failure

### SFTP Storage
```bash
Repository type: sftp
Example: sftp:backup-user@backup.example.com:/backups/panelalpha
```
- Best for: Remote server backups, existing SSH infrastructure
- Pros: Secure, widely supported
- Cons: Requires SSH access setup

### S3-Compatible Storage
```bash
Repository type: s3
Supports: AWS S3, Hetzner Storage, MinIO, DigitalOcean Spaces
Example: s3:s3.eu-west-1.amazonaws.com/my-bucket/panelalpha-snapshots
```
- Best for: Production environments, scalable storage
- Pros: Highly available, scalable, cost-effective
- Cons: Requires cloud account setup

## Usage Examples

### Creating Snapshots

```bash
# Create a one-time snapshot
sudo ./panelalpha-snapshot.sh --snapshot

# List all available snapshots
sudo ./panelalpha-snapshot.sh --list-snapshots

# Delete a specific snapshot
sudo ./panelalpha-snapshot.sh --delete-snapshots a1b2c3d4
```

### Restore Operations

#### Same Server Restore
```bash
# Restore from latest snapshot
sudo ./panelalpha-snapshot.sh --restore latest

# Restore from specific snapshot
sudo ./panelalpha-snapshot.sh --restore a1b2c3d4
```

#### New Server Migration
1. **Install PanelAlpha** on the new server (basic installation)
2. **Install snapshot tool**:
   ```bash
   # Copy panelalpha-snapshot.sh to new server
   sudo ./panelalpha-snapshot.sh --install
   ```
3. **Configure repository** (use same settings as source):
   ```bash
   sudo ./panelalpha-snapshot.sh --setup
   ```
4. **Test connection**:
   ```bash
   sudo ./panelalpha-snapshot.sh --test-connection
   ```
5. **Restore from snapshot**:
   ```bash
   sudo ./panelalpha-snapshot.sh --restore a1b2c3d4
   ```

The restore process automatically:
- Updates database connection settings
- Adjusts server IP addresses in system settings
- Configures trusted hosts
- Recreates Docker volumes
- Restores SSL certificates

### Automation

```bash
# Install automatic daily snapshots
sudo ./panelalpha-snapshot.sh --cron install

# Check automation status
sudo ./panelalpha-snapshot.sh --cron status

# Remove automatic snapshots
sudo ./panelalpha-snapshot.sh --cron remove
```

## Configuration

Configuration is stored in `/opt/panelalpha/app/.env-backup`:

```bash
# Repository settings
RESTIC_REPOSITORY="s3:s3.eu-west-1.amazonaws.com/my-bucket/panelalpha-snapshots"
RESTIC_PASSWORD="your-encryption-password"

# S3 credentials (if applicable)
AWS_ACCESS_KEY_ID="your-access-key"
AWS_SECRET_ACCESS_KEY="your-secret-key"

# Snapshot settings
BACKUP_RETENTION_DAYS=30
BACKUP_HOUR=2
BACKUP_TAG_PREFIX="panelalpha"

# System paths
LOG_FILE="/var/log/panelalpha-snapshot.log"
BACKUP_TEMP_DIR="/var/tmp"
RESTIC_CACHE_DIR="/var/cache/restic"
```

## Security

- **Encryption**: All snapshots are encrypted using AES-256
- **Access Control**: Configuration files have restricted permissions (600)
- **Credential Management**: S3 credentials are only exported during operations
- **Network Security**: HTTPS/TLS for all remote communications

## Troubleshooting

### Common Issues

1. **Permission Denied**:
   ```bash
   # Ensure running as root
   sudo ./panelalpha-snapshot.sh --snapshot
   ```

2. **Docker Not Running**:
   ```bash
   sudo systemctl start docker
   sudo systemctl enable docker
   ```

3. **Repository Connection Failed**:
   ```bash
   # Test connection
   sudo ./panelalpha-snapshot.sh --test-connection
   
   # Verify credentials in configuration file
   sudo nano /opt/panelalpha/app/.env-backup
   ```

4. **Insufficient Disk Space**:
   ```bash
   # Check available space
   df -h /var/tmp
   
   # Clean up old snapshots
   sudo ./panelalpha-snapshot.sh --delete-snapshots old-snapshot-id
   ```

### Log Files

Monitor operations in `/var/log/panelalpha-snapshot.log`:

```bash
# View recent activity
sudo tail -f /var/log/panelalpha-snapshot.log

# Search for errors
sudo grep ERROR /var/log/panelalpha-snapshot.log
```
