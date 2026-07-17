<div align="center">
  <img src="img/logo.svg" alt="PanelAlpha Snapshot Tool" width="96" />
  <h1>PanelAlpha Snapshot Tool</h1>
  <p><strong>Encrypted disaster-recovery snapshots for PanelAlpha.</strong></p>
  <p>
    <a href="https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/releases"><img alt="Release" src="https://img.shields.io/github/v/release/panelalpha/PanelAlpha-Snapshot-Tool"></a>
    <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/panelalpha/PanelAlpha-Snapshot-Tool"></a>
  </p>
</div>

---

One script. Auto-detects your install. Backs up databases, volumes, config, and (on Engine / single-server) `/home` + user projects. Stored with **Restic AES-256**.

| Detected type | Paths |
| --- | --- |
| **multi-server** | `/opt/panelalpha/app` |
| **single-server** | `/opt/panelalpha/app-lite` + `/opt/panelalpha/shared-hosting` |
| **engine** | `/opt/panelalpha/shared-hosting` |

> This is **host-level DR** (SSH / sudo). Per-site WordPress backups in the Admin / Client Area are a separate feature.

---

### Installation

```bash
wget -O /opt/panelalpha/pasnap.sh https://raw.githubusercontent.com/panelalpha/PanelAlpha-Snapshot-Tool/main/pasnap.sh
```

```bash
chmod +x /opt/panelalpha/pasnap.sh
```

```bash
sudo /opt/panelalpha/pasnap.sh --install
```

Requirements: Linux (Debian / Ubuntu recommended), Docker 20.10+, root, ~3GB+ free disk (more if Engine `/home` is large).

---

### Quick start

```bash
# Configure storage + encryption password, then first snapshot
sudo /opt/panelalpha/pasnap.sh --quickstart

# Or step by step
sudo /opt/panelalpha/pasnap.sh --setup
sudo /opt/panelalpha/pasnap.sh --test-connection
sudo /opt/panelalpha/pasnap.sh --verify-database
sudo /opt/panelalpha/pasnap.sh --snapshot
sudo /opt/panelalpha/pasnap.sh --cron install
```

Storage backends: **local**, **SFTP**, or **S3-compatible** (AWS, Hetzner, MinIO, DigitalOcean Spaces, …).

> [!IMPORTANT]
> Keep the Restic encryption password offline. Without it, snapshots cannot be restored.

---

### Commands

```bash
sudo pasnap.sh --snapshot              # Create snapshot
sudo pasnap.sh --snapshot-bg           # Create in background
sudo pasnap.sh --list-snapshots        # List snapshots
sudo pasnap.sh --restore latest        # Restore latest
sudo pasnap.sh --restore <id>          # Restore specific ID
sudo pasnap.sh --delete-snapshots <id> # Delete snapshot
sudo pasnap.sh --verify-database       # Check DB credentials
sudo pasnap.sh --test-connection       # Check repository
sudo pasnap.sh --cron install|status|remove
sudo pasnap.sh --version
sudo pasnap.sh --help
```

Typical paths:

| Path | Purpose |
| --- | --- |
| `/opt/panelalpha/pasnap.sh` | Script |
| `/opt/panelalpha/pasnap/.env-backup` | Config (mode `600`) |
| `/var/log/pasnap.log` | Logs |

---

### What gets snapshotted

**multi-server** — API database, `api-storage` / `database-api-data` / `redis-data`, `.env` / `.env-api`, packages, SSL.

**engine** — Core + users databases, engine volumes, `.env` / `.env-core`, `users/`, `/home`, SSL.

**single-server** — Full engine scope **plus** app-lite panel DB (from `database-core`), `.env`, compose, `data/api-storage`.

---

### Documentation

- [Installation](docs/installation.md)
- [Storage backends](docs/storage-backends.md)
- [Usage](docs/usage.md)
- [Migration](docs/migration.md)
- [Configuration](docs/configuration.md)
- [Troubleshooting](docs/troubleshooting.md)

---

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

Issues: [GitHub Issues](https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/issues)

---

### License

[Apache-2.0](LICENSE) — see the license file for details.
