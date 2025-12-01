# Usage & Commands

Complete reference for all PanelAlpha Snapshot Tool commands.

## Command Reference

### Snapshot Operations

#### Create a Snapshot

```bash
sudo ./pasnap.sh --snapshot
```

Creates a complete backup of your PanelAlpha installation including databases, Docker volumes, and configuration files.

#### List Snapshots

```bash
sudo ./pasnap.sh --list-snapshots
```

Displays all available snapshots with their IDs, dates, and sizes.

#### Delete a Snapshot

```bash
sudo ./pasnap.sh --delete-snapshots <snapshot-id>
```

Remove a specific snapshot by its ID (e.g., `a1b2c3d4`).

---

### Restore Operations

#### Restore Latest Snapshot

```bash
sudo ./pasnap.sh --restore latest
```

Restores from the most recent snapshot.

#### Restore Specific Snapshot

```bash
sudo ./pasnap.sh --restore <snapshot-id>
```

Restores from a specific snapshot (e.g., `a1b2c3d4`).

> ⚠️ **Warning**: Restoration will replace all current data!

---

### Automation

#### Install Cron Job

```bash
sudo ./pasnap.sh --cron install
```

Sets up automatic daily snapshots.

#### Check Cron Status

```bash
sudo ./pasnap.sh --cron status
```

Shows current automation status and next scheduled run.

#### Remove Cron Job

```bash
sudo ./pasnap.sh --cron remove
```

Disables automatic snapshots.

---

### Setup & Configuration

#### Interactive Setup

```bash
sudo ./pasnap.sh --setup
```

Launches the interactive setup wizard for configuring storage backend.

#### Install Dependencies

```bash
sudo ./pasnap.sh --install
```

Installs required tools and sets up the environment.

#### Test Connection

```bash
sudo ./pasnap.sh --test-connection
```

Verifies connectivity to the configured storage backend.

---

## What Gets Captured

### Databases

| Component | Description |
|-----------|-------------|
| PanelAlpha API Database | Complete MySQL dump with routines and triggers |
| Matomo Database | Analytics and statistics data |
| Users Databases | (Engine only) Per-user databases |

### Docker Volumes

| Volume | Description |
|--------|-------------|
| `api-storage` | PanelAlpha application data |
| `database-api-data` | MySQL data files |
| `redis-data` | Cache and session data |
| `core-storage` | (Engine only) Core application data |

### Configuration Files

| File/Directory | Description |
|----------------|-------------|
| `docker-compose.yml` | Container orchestration configuration |
| `.env` files | Environment variables and secrets |
| `packages/` | Custom packages and extensions |
| SSL certificates | Let's Encrypt certificates |
| Nginx configurations | Web server settings |

---

## Common Workflows

### Daily Backup Routine

```bash
# Create snapshot
sudo ./pasnap.sh --snapshot

# Verify it was created
sudo ./pasnap.sh --list-snapshots
```

### Before Major Changes

```bash
# Create a snapshot before updates
sudo ./pasnap.sh --snapshot

# Note the snapshot ID for potential rollback
sudo ./pasnap.sh --list-snapshots
```

### Cleanup Old Snapshots

```bash
# List all snapshots
sudo ./pasnap.sh --list-snapshots

# Delete old ones
sudo ./pasnap.sh --delete-snapshots old-snapshot-id
```
