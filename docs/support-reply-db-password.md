# Support reply draft — database password error during snapshot

Use this as a starting point when replying to customers who report database password errors with the Snapshot Tool on PanelAlpha Control Panel.

---

Thank you for the detailed report — the documentation step you followed is outdated for PanelAlpha Control Panel installations.

**You do not need to add or move the password anywhere.** The Snapshot Tool reads it automatically from `/opt/panelalpha/app/.env` using the variable `API_MYSQL_PASSWORD` (not `DB_*`). Seeing `API_MYSQL_PASSWORD` in your `.env` is correct.

The error means the password in `.env` does not match what the MariaDB container was initialized with. Please run:

```bash
cd /opt/panelalpha/app
sudo /opt/panelalpha/pasnap.sh --verify-database
```

Then test the connection manually:

```bash
cd /opt/panelalpha/app
API_PASS=$(grep '^API_MYSQL_PASSWORD=' .env | cut -d'=' -f2-)
docker compose exec database-api mysql -u panelalpha -p"$API_PASS" -e "SELECT 1;"
```

- If this **fails** but PanelAlpha UI works, compare with the password the API container actually uses:

  ```bash
  docker compose exec api printenv DB_PASSWORD
  ```

  If they differ, update `API_MYSQL_PASSWORD` in `.env` to match `DB_PASSWORD`, then reset the MariaDB user password to the same value. We can provide exact SQL if needed. Please also share the output of:

  ```bash
  sudo tail -50 /var/log/pasnap.log
  ```

- If the manual test **succeeds** but snapshots still fail, update to Snapshot Tool v1.2.3 or later (fixes password parsing for special characters) and retry:

  ```bash
  sudo /opt/panelalpha/pasnap.sh --update
  sudo /opt/panelalpha/pasnap.sh --snapshot
  ```

We are updating the troubleshooting page at panelalpha.com to reference `API_MYSQL_PASSWORD` and clearer recovery steps.

---

## Internal notes

- Root cause is usually docs mismatch (`grep DB_`) plus possible `.env` / DB volume desync.
- Do **not** recommend deleting the `database-api-data` volume unless the customer accepts data loss.
- Debian 13 upgrade path is unrelated unless containers/volumes were recreated during migration.
