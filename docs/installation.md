# Installation Guide

## System Requirements

- **Operating System**: Ubuntu 18.04+ or compatible Linux
- **Docker**: Version 20.10 or higher
- **Disk Space**: At least 3GB free (more for Engine `/home`)
- **Permissions**: Root access (sudo)

## Step 1: Download the Script

```bash
wget -P /opt/panelalpha/ https://raw.githubusercontent.com/panelalpha/PanelAlpha-Snapshot-Tool/main/pasnap.sh
chmod +x /opt/panelalpha/pasnap.sh
```

## Step 2: Install Dependencies

```bash
sudo /opt/panelalpha/pasnap.sh --install
```

This installs restic, jq, rsync (if missing) and verifies Docker / Docker Compose.

## Step 3: Configure Storage Backend

```bash
sudo /opt/panelalpha/pasnap.sh --setup
```

The wizard:

1. Shows the detected installation type (multi-server / single-server / engine)
2. Asks for storage type (local default path `/backup/panelalpha`, SFTP, or S3)
3. Sets the **encryption password** (min 8 characters — required for every restore)
4. Sets retention (default 30 days) and cron hour (default 2)
5. Tests the repository and verifies database credentials

See [Storage Backends](storage-backends.md).

## Step 4: Verify

```bash
sudo /opt/panelalpha/pasnap.sh --test-connection
sudo /opt/panelalpha/pasnap.sh --verify-database
```

## Step 5: Create First Snapshot

```bash
sudo /opt/panelalpha/pasnap.sh --snapshot
```

## One-shot alternative

On a fresh host you can combine install + setup + first snapshot:

```bash
sudo /opt/panelalpha/pasnap.sh --quickstart
```

## Optional: Automatic Backups

```bash
sudo /opt/panelalpha/pasnap.sh --cron install
sudo /opt/panelalpha/pasnap.sh --cron status
```

## Application Type Detection

| Type | Paths |
|------|--------|
| **multi-server** | `/opt/panelalpha/app` |
| **single-server** | `/opt/panelalpha/app-lite` + `/opt/panelalpha/shared-hosting` |
| **engine** | `/opt/panelalpha/shared-hosting` without app-lite |

No manual type flag is required. If detection fails, the tool exits instead of guessing.

## Next Steps

- [Configure Storage Backends](storage-backends.md)
- [Learn Usage & Commands](usage.md)
- [Set Up Server Migration](migration.md)
