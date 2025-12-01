# Installation Guide

## System Requirements

- **Operating System**: Ubuntu 18.04+ or compatible Linux distribution
- **Docker**: Version 20.10 or higher
- **Disk Space**: At least 3GB free space
- **Internet**: Required for cloud storage backends
- **Permissions**: Root access (sudo)

## Step 1: Download the Script

```bash
wget -P /opt/panelalpha/ https://raw.githubusercontent.com/panelalpha/PanelAlpha-Snapshot-Tool/main/pasnap.sh
chmod +x /opt/panelalpha/pasnap.sh
```

## Step 2: Install Dependencies

Run the installation command to set up all necessary tools (restic, etc.):

```bash
sudo /opt/panelalpha/pasnap.sh --install
```

This will:
- Install restic backup tool
- Create necessary directories
- Set up log files
- Configure permissions

## Step 3: Configure Storage Backend

Run the interactive setup wizard:

```bash
sudo /opt/panelalpha/pasnap.sh --setup
```

The wizard will guide you through:
1. Selecting storage type (local, SFTP, or S3)
2. Configuring connection details
3. Setting encryption password
4. Testing the connection

See [Storage Backends](storage-backends.md) for detailed configuration options.

## Step 4: Verify Installation

Test the connection to your storage backend:

```bash
sudo /opt/panelalpha/pasnap.sh --test-connection
```

## Step 5: Create First Snapshot

Create your first backup:

```bash
sudo /opt/panelalpha/pasnap.sh --snapshot
```

## Optional: Enable Automatic Backups

Set up daily automatic snapshots:

```bash
sudo /opt/panelalpha/pasnap.sh --cron install
```

Check the status:

```bash
sudo /opt/panelalpha/pasnap.sh --cron status
```

## Application Type Detection

The tool automatically detects your installation:

- **Control Panel**: Detected at `/opt/panelalpha/app`
- **Engine**: Detected at `/opt/panelalpha/engine`

No manual configuration is needed - the tool handles this automatically.

## Next Steps

- [Configure Storage Backends](storage-backends.md)
- [Learn Usage & Commands](usage.md)
- [Set Up Server Migration](migration.md)
