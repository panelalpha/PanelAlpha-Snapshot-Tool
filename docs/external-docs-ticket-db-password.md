# Docs ticket: Update Snapshot Tool troubleshooting page

**Target URL:** https://www.panelalpha.com/documentation/troubleshooting-center/backups/snapshot-tool-issues/

**Priority:** High — customer-reported confusion blocking backups before production

## Summary

The Snapshot Tool troubleshooting page references outdated script names, log paths, configuration paths, and database environment variables. Customers following the page cannot diagnose database connection errors on PanelAlpha Control Panel installations.

## Required updates

### 1. Replace outdated command/script references

| Outdated | Current |
|---|---|
| `panelalpha-snapshot.sh` | `pasnap.sh` (typically `/opt/panelalpha/pasnap.sh`) |
| `/var/log/panelalpha-snapshot.log` | `/var/log/pasnap.log` |
| `/opt/panelalpha/app/.env-backup` | `/opt/panelalpha/pasnap/.env-backup` (legacy path auto-migrates) |

### 2. Fix "Snapshot Creation Fails with Database Connection Error"

**Remove:**

```bash
sudo cat /opt/panelalpha/app/.env | grep DB_
```

**Replace with installation-type guidance:**

**Control Panel** (`/opt/panelalpha/app`):

```bash
grep API_MYSQL_PASSWORD /opt/panelalpha/app/.env
sudo /opt/panelalpha/pasnap.sh --verify-database
```

**Engine** (`/opt/panelalpha/engine`):

```bash
grep -E 'CORE_MYSQL_PASSWORD|USERS_MYSQL_ROOT_PASSWORD' /opt/panelalpha/engine/.env /opt/panelalpha/engine/.env-core 2>/dev/null
sudo /opt/panelalpha/pasnap.sh --verify-database
```

**Single-server** (if documented separately):

```bash
grep DB_PASSWORD /opt/panelalpha/app/.env
```

### 3. Add "Password out of sync" section

Explain that:

- The Snapshot Tool reads database passwords automatically from the PanelAlpha `.env` file.
- Customers do **not** need to copy the password into another file.
- For Control Panel, the correct variable is `API_MYSQL_PASSWORD` (not `DB_*` in the root `.env`).
- MariaDB passwords are set when the database volume is first created; changing `.env` later without updating the DB user causes connection failures.

**Diagnostic steps (Control Panel):**

```bash
cd /opt/panelalpha/app
API_PASS=$(grep '^API_MYSQL_PASSWORD=' .env | cut -d'=' -f2-)
docker compose exec database-api mysql -u panelalpha -p"$API_PASS" -e "SELECT 1;"
docker compose exec api printenv DB_PASSWORD
```

If PanelAlpha works but the first command fails, compare `API_MYSQL_PASSWORD` with `DB_PASSWORD` and synchronize.

### 4. Update restore troubleshooting container names

Use `database-api` (not generic `database`) for Control Panel examples:

```bash
docker compose exec database-api mysql -u panelalpha -p -e "SELECT 1;"
```

## Acceptance criteria

- [ ] No references to `panelalpha-snapshot.sh` or `/var/log/panelalpha-snapshot.log`
- [ ] Database troubleshooting names `API_MYSQL_PASSWORD` for Control Panel
- [ ] `--verify-database` documented as first diagnostic step
- [ ] Configuration path documents `/opt/panelalpha/pasnap/.env-backup`
- [ ] Page explains that passwords are read automatically and desync is a common cause

## Related release

PanelAlpha Snapshot Tool v1.2.3 — adds `--verify-database`, improved password parsing, and clearer error messages.
