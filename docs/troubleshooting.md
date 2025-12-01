# Troubleshooting

Common issues and solutions for PanelAlpha Snapshot Tool.

## Quick Diagnostics

```bash
# Check logs for errors
sudo tail -50 /var/log/pasnap.log

# Test storage connection
sudo ./pasnap.sh --test-connection

# Verify Docker is running
sudo systemctl status docker

# Check disk space
df -h
```

---

## Common Issues

### Permission Denied

**Symptom**: `Permission denied` errors when running commands.

**Solution**: Always run with `sudo`:

```bash
sudo ./pasnap.sh --snapshot
```

---

### Docker Not Running

**Symptom**: `Cannot connect to Docker daemon` or similar errors.

**Solution**:

```bash
# Start Docker
sudo systemctl start docker

# Enable Docker to start on boot
sudo systemctl enable docker

# Verify Docker is running
sudo systemctl status docker
```

---

### Repository Connection Failed

**Symptom**: `unable to open config file` or connection timeout errors.

**Solution**:

1. Test the connection:
   ```bash
   sudo ./pasnap.sh --test-connection
   ```

2. Verify configuration:
   ```bash
   sudo cat /opt/panelalpha/app/.env-backup
   ```

3. For S3:
   - Check AWS credentials are correct
   - Verify bucket exists and is accessible
   - Check region is correct

4. For SFTP:
   - Verify SSH key is set up
   - Test SSH connection manually: `ssh user@hostname`
   - Check remote directory exists

---

### Insufficient Disk Space

**Symptom**: `no space left on device` errors.

**Solution**:

1. Check available space:
   ```bash
   df -h /var/tmp
   df -h /
   ```

2. Clean up old snapshots:
   ```bash
   sudo ./pasnap.sh --list-snapshots
   sudo ./pasnap.sh --delete-snapshots <old-snapshot-id>
   ```

3. Clean Docker resources:
   ```bash
   docker system prune -f
   ```

---

### Database Backup Fails

**Symptom**: Errors related to MySQL or database dumps.

**Solution**:

1. Check if PanelAlpha is running:
   ```bash
   cd /opt/panelalpha/app  # or /opt/panelalpha/engine
   docker compose ps
   ```

2. Verify database container is healthy:
   ```bash
   docker compose logs database-api
   ```

3. Check database credentials in `.env` file

4. Try restarting containers:
   ```bash
   docker compose down
   docker compose up -d
   ```

---

### Snapshot Restoration Fails

**Symptom**: Errors during `--restore` operation.

**Solution**:

1. Ensure PanelAlpha is stopped:
   ```bash
   cd /opt/panelalpha/app
   docker compose down
   ```

2. Check disk space is sufficient

3. Verify snapshot exists:
   ```bash
   sudo ./pasnap.sh --list-snapshots
   ```

4. Check logs for specific errors:
   ```bash
   sudo tail -100 /var/log/pasnap.log
   ```

---

### Cron Job Not Running

**Symptom**: Automatic backups are not being created.

**Solution**:

1. Check cron status:
   ```bash
   sudo ./pasnap.sh --cron status
   ```

2. View cron jobs:
   ```bash
   sudo crontab -l
   ```

3. Check cron service:
   ```bash
   sudo systemctl status cron
   ```

4. Reinstall cron job:
   ```bash
   sudo ./pasnap.sh --cron remove
   sudo ./pasnap.sh --cron install
   ```

---

### SSL Certificate Issues After Restore

**Symptom**: SSL errors or certificate warnings after restoration.

**Solution**:

1. Regenerate certificates:
   ```bash
   cd /opt/panelalpha/app
   docker compose exec nginx certbot renew --force-renewal
   ```

2. Restart nginx:
   ```bash
   docker compose restart nginx
   ```

---

## Log Analysis

### View Recent Logs

```bash
sudo tail -f /var/log/pasnap.log
```

### Search for Errors

```bash
sudo grep -i error /var/log/pasnap.log
```

### Search for Specific Date

```bash
sudo grep "2024-01-15" /var/log/pasnap.log
```

---

## Getting Help

If you're still experiencing issues:

1. **Collect diagnostic information**:
   ```bash
   # System info
   uname -a
   docker --version
   
   # Recent logs
   sudo tail -100 /var/log/pasnap.log > pasnap-debug.log
   
   # Storage test
   sudo ./pasnap.sh --test-connection 2>&1 >> pasnap-debug.log
   ```

2. **Open an issue** on GitHub:
   - [GitHub Issues](https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/issues)
   - Include the diagnostic information (remove sensitive data)

---

## Recovery Procedures

### Complete Reset

If the tool is in an inconsistent state:

```bash
# Remove configuration
sudo rm /opt/panelalpha/app/.env-backup

# Reinstall
sudo ./pasnap.sh --install

# Reconfigure
sudo ./pasnap.sh --setup
```

### Manual Database Restore

If automatic restore fails, you can manually restore the database:

```bash
# Extract database dump from snapshot (contact support for assistance)
# Then import manually:
docker compose exec -T database-api mysql -u root -p"$MYSQL_ROOT_PASSWORD" < dump.sql
```
