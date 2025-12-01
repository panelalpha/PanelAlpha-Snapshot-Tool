# Server Migration

Guide for moving PanelAlpha to a new server using snapshots.

## Overview

The migration process involves:
1. Creating a snapshot on the old server
2. Installing PanelAlpha on the new server
3. Configuring the snapshot tool on the new server
4. Restoring the snapshot

## Step-by-Step Migration

### On the Old Server

#### 1. Create a Fresh Snapshot

```bash
sudo ./pasnap.sh --snapshot
```

#### 2. Note the Snapshot ID

After the snapshot completes, note the snapshot ID from the output (e.g., `a1b2c3d4`).

You can also list snapshots to find it:

```bash
sudo ./pasnap.sh --list-snapshots
```

#### 3. Note Your Storage Configuration

If using remote storage (SFTP or S3), note your configuration:

```bash
sudo cat /opt/panelalpha/app/.env-backup
```

---

### On the New Server

#### 1. Install PanelAlpha

Perform a basic PanelAlpha installation following the official documentation.

#### 2. Install Snapshot Tool

```bash
wget -P /opt/panelalpha/ https://raw.githubusercontent.com/panelalpha/PanelAlpha-Snapshot-Tool/main/pasnap.sh
chmod +x /opt/panelalpha/pasnap.sh
sudo /opt/panelalpha/pasnap.sh --install
```

#### 3. Configure Storage (Same as Old Server)

```bash
sudo ./pasnap.sh --setup
```

Use the **exact same storage configuration** as on the old server to access your existing snapshots.

#### 4. Test Connection

```bash
sudo ./pasnap.sh --test-connection
```

#### 5. Verify Snapshot Access

```bash
sudo ./pasnap.sh --list-snapshots
```

You should see the snapshot you created on the old server.

#### 6. Restore the Snapshot

```bash
sudo ./pasnap.sh --restore <snapshot-id>
```

Or restore the latest:

```bash
sudo ./pasnap.sh --restore latest
```

---

## What the Restore Process Does

The restore automatically:

- ✅ Restores all databases
- ✅ Recreates Docker volumes with original data
- ✅ Restores configuration files
- ✅ Updates database connection settings
- ✅ Adjusts server IP addresses in system settings
- ✅ Configures trusted hosts
- ✅ Restores SSL certificates

---

## Post-Migration Checklist

After restoration:

1. **Verify PanelAlpha is running**:
   ```bash
   docker compose ps
   ```

2. **Check application access**:
   - Access the web interface
   - Verify login works

3. **Update DNS** (if needed):
   - Point your domain to the new server IP

4. **Test functionality**:
   - Create a test site
   - Verify existing sites work

5. **Set up automatic backups** on the new server:
   ```bash
   sudo ./pasnap.sh --cron install
   ```

---

## Troubleshooting Migration

### Snapshot Not Visible on New Server

- Verify storage configuration matches exactly
- Check network connectivity to storage backend
- Run `--test-connection` to diagnose issues

### Restore Fails

- Check available disk space: `df -h`
- Verify Docker is running: `sudo systemctl status docker`
- Check logs: `sudo tail -f /var/log/pasnap.log`

### Application Not Starting After Restore

1. Check Docker containers: `docker compose ps`
2. View container logs: `docker compose logs`
3. Verify `.env` file is properly restored
4. Restart services: `docker compose down && docker compose up -d`

---

## Best Practices

- **Test migration** on a staging server first
- **Keep the old server running** until migration is verified
- **Document your configuration** before migration
- **Create a fresh snapshot** immediately before migration
- **Update DNS TTL** to a low value before migration for faster propagation
