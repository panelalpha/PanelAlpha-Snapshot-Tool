# Usage & Commands

Complete reference for PanelAlpha Snapshot Tool commands (v1.3.0+).

## Command Reference

### Snapshot Operations

#### Create a Snapshot

```bash
sudo ./pasnap.sh --snapshot
```

Creates a full encrypted backup for the detected installation type.

#### Create Snapshot in Background

```bash
sudo ./pasnap.sh --snapshot-bg
```

Runs `--snapshot` under `nohup` so it survives terminal close. Progress: `tail -f /var/log/pasnap.log`.

#### List Snapshots

```bash
sudo ./pasnap.sh --list-snapshots
```

#### Delete a Snapshot

```bash
sudo ./pasnap.sh --delete-snapshots <snapshot-id>
```

---

### Restore Operations

```bash
sudo ./pasnap.sh --restore latest
sudo ./pasnap.sh --restore <snapshot-id>
```

> Warning: restore replaces current data for the stacks on this host.

If the snapshot was taken on a different installation type than the current host, the tool warns and asks for confirmation.

---

### Automation

```bash
sudo ./pasnap.sh --cron install
sudo ./pasnap.sh --cron status
sudo ./pasnap.sh --cron remove
```

---

### Setup & Diagnostics

```bash
sudo ./pasnap.sh --install           # Dependencies (restic, jq, rsync)
sudo ./pasnap.sh --setup             # Interactive storage + encryption password
sudo ./pasnap.sh --quickstart        # install (if needed) + setup (if needed) + snapshot
sudo ./pasnap.sh --test-connection   # Repository connectivity
sudo ./pasnap.sh --verify-database   # DB credentials for the detected profile
sudo ./pasnap.sh --update            # Force self-update check
sudo ./pasnap.sh --version
sudo ./pasnap.sh --help
```

---

## What Gets Captured

### multi-server (`/opt/panelalpha/app`)

| Component | Details |
|-----------|---------|
| Database | `database-api` → `panelalpha` dump |
| Volumes | `api-storage`, `database-api-data`, `redis-data` |
| Config | `docker-compose.yml`, `.env`, `.env-api`, `packages/`, Let's Encrypt |

### engine (`/opt/panelalpha/shared-hosting`)

| Component | Details |
|-----------|---------|
| Databases | Core + all users DBs |
| Volumes | `core-storage`, `database-core-data`, `database-users-data` |
| Paths | `users/` projects, full `/home` |
| Config | `.env`, `.env-core`, compose, SSL |

### single-server (`app-lite` + engine)

Everything from **engine**, plus:

| Component | Details |
|-----------|---------|
| Panel DB | Schema from `database-core` using app-lite `DB_*` → `panelalpha-panel.sql` |
| Panel files | `app-lite/.env`, `docker-compose.yml`, `data/api-storage` |

---

## Common Workflows

### Daily backup

```bash
sudo ./pasnap.sh --snapshot
sudo ./pasnap.sh --list-snapshots
```

### Before major changes

```bash
sudo ./pasnap.sh --snapshot
sudo ./pasnap.sh --list-snapshots   # note the ID
```

### Fresh host

```bash
sudo ./pasnap.sh --quickstart
sudo ./pasnap.sh --cron install
```
