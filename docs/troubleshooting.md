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
   sudo cat /opt/panelalpha/pasnap/.env-backup
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

**Symptom**: Errors related to MariaDB/MySQL or database dumps, for example:

```
Cannot connect to PanelAlpha database (user: panelalpha)
Verify API_MYSQL_PASSWORD in /opt/panelalpha/app/.env matches the running database
```

**Solution**:

1. Run the built-in database diagnostic:
   ```bash
   sudo /opt/panelalpha/pasnap.sh --verify-database
   ```

2. Check if PanelAlpha is running:
   ```bash
   cd /opt/panelalpha/app              # multi-server
   # or
   cd /opt/panelalpha/shared-hosting   # engine / single-server
   docker compose ps
   ```


3. Verify the correct database password variables for your installation type:

   | Installation | Environment file | Password variable | Database user | Container |
   |---|---|---|---|---|
   | multi-server | `/opt/panelalpha/app/.env` (or `.env-api`) | `API_MYSQL_PASSWORD` | `panelalpha` | `database-api` |
   | engine / single-server | `/opt/panelalpha/shared-hosting/.env` | `CORE_MYSQL_PASSWORD` | `core` | `database-core` |
   | engine / single-server | same as above | `USERS_MYSQL_ROOT_PASSWORD` | `root` | `database-users` |
   | single-server (panel) | `/opt/panelalpha/app-lite/.env` | `DB_PASSWORD` (+ `DB_DATABASE`, `DB_USERNAME`) | panel user | `database-core` |

   Multi-server example:
   ```bash
   grep API_MYSQL_PASSWORD /opt/panelalpha/app/.env /opt/panelalpha/app/.env-api 2>/dev/null
   ```

   Engine / single-server example:
   ```bash
   grep -E 'CORE_MYSQL_PASSWORD|USERS_MYSQL_ROOT_PASSWORD' \
     /opt/panelalpha/shared-hosting/.env /opt/panelalpha/shared-hosting/.env-core 2>/dev/null
   grep -E 'DB_DATABASE|DB_USERNAME|DB_PASSWORD' /opt/panelalpha/app-lite/.env 2>/dev/null
   ```

   You do **not** need to copy the password into pasnap config. The tool reads PanelAlpha env files automatically.

4. Test the database connection manually:

   **multi-server:**
   ```bash
   cd /opt/panelalpha/app
   API_PASS=$(grep '^API_MYSQL_PASSWORD=' .env | cut -d'=' -f2-)
   docker compose exec database-api mariadb -u panelalpha -p"$API_PASS" -e "SELECT 1;"
   ```

   **engine / single-server:**
   ```bash
   cd /opt/panelalpha/shared-hosting
   CORE_PASS=$(grep '^CORE_MYSQL_PASSWORD=' .env .env-core 2>/dev/null | head -1 | cut -d'=' -f2-)
   docker compose exec database-core mariadb -u core -p"$CORE_PASS" -e "SELECT 1;"
   ```

   On older MySQL-based database images, use `mysql` instead of `mariadb`.

5. If PanelAlpha works but the test above fails, the password in `.env` may be out of sync with the database volume. Compare with the running container env (`MYSQL_PASSWORD` / `DB_PASSWORD`).

6. Verify database container health:
   ```bash
   docker compose -f /opt/panelalpha/app/docker-compose.yml logs database-api
   docker compose -f /opt/panelalpha/shared-hosting/docker-compose.yml logs database-core database-users
   ```

7. Review snapshot logs:
   ```bash
   sudo tail -100 /var/log/pasnap.log
   ```

---

### Installation Type Not Detected

**Symptom**: `PanelAlpha installation not detected` and listed expected paths.

**Solution**: Confirm the host layout matches one of:

- multi-server: `/opt/panelalpha/app/docker-compose.yml`
- single-server: `/opt/panelalpha/app-lite/docker-compose.yml` **and** `/opt/panelalpha/shared-hosting/docker-compose.yml`
- engine: `/opt/panelalpha/shared-hosting/docker-compose.yml` without app-lite

There is no silent fallback to a guessed path.

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
sudo rm /opt/panelalpha/pasnap/.env-backup

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
docker compose exec -T database-api mariadb -u root -p"$MYSQL_ROOT_PASSWORD" < dump.sql
```

On older MySQL-based database images, use `mysql` instead of `mariadb`.
