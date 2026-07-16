<div align="center">
  <img src="img/logo.svg" alt="PanelAlpha Snapshot Tool" width="100"/>
  <h1>PanelAlpha Snapshot Tool</h1>
  <h3>Secure Snapshots for PanelAlpha</h3>

  <a href="https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/releases"><img alt="GitHub release" src="https://img.shields.io/github/v/release/panelalpha/PanelAlpha-Snapshot-Tool"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/panelalpha/PanelAlpha-Snapshot-Tool"></a>

</div>

## Intro

**PanelAlpha Snapshot Tool** creates encrypted, restorable disaster-recovery snapshots of a PanelAlpha host: databases, Docker volumes, configuration, and (for Engine / single-server) customer data under `/home` and user projects.

It auto-detects one of three installation types:

| Type | Paths |
|------|--------|
| **multi-server** | `/opt/panelalpha/app` |
| **single-server** | `/opt/panelalpha/app-lite` **and** `/opt/panelalpha/shared-hosting` (or `engine`) |
| **engine** | `/opt/panelalpha/shared-hosting` or `/opt/panelalpha/engine` (without app-lite) |

Snapshots are stored with **Restic (AES-256)**. Without the repository password, restore is impossible.

> This tool is **install-level DR** (SSH/sudo). Per-site WordPress backups in the Admin/Client Area are a separate product feature.

## Features

- Full snapshots: databases, volumes, config, SSL; Engine/single-server also `/home` and `users/`
- Single-server: engine **plus** app-lite panel DB, `.env`, and `data/api-storage`
- Local, SFTP, or S3-compatible storage
- Daily cron automation
- AES-256 encryption via Restic
- Auto-detection of installation type (fail-closed if unknown)
- Simple CLI; optional one-shot `--quickstart`

## Installation

```bash
wget -O /opt/panelalpha/pasnap.sh https://raw.githubusercontent.com/panelalpha/PanelAlpha-Snapshot-Tool/main/pasnap.sh
chmod +x /opt/panelalpha/pasnap.sh
sudo /opt/panelalpha/pasnap.sh --install
```

Detailed guides: [Documentation](docs/README.md).

## Quick Start

```bash
# One-shot: install tools + configure + first snapshot
sudo ./pasnap.sh --quickstart

# Or step by step:
sudo ./pasnap.sh --setup
sudo ./pasnap.sh --test-connection
sudo ./pasnap.sh --verify-database
sudo ./pasnap.sh --snapshot
sudo ./pasnap.sh --cron install
```

## Documentation

- [Installation Guide](docs/installation.md)
- [Storage Backends](docs/storage-backends.md)
- [Usage & Commands](docs/usage.md)
- [Server Migration](docs/migration.md)
- [Configuration Reference](docs/configuration.md)
- [Troubleshooting](docs/troubleshooting.md)

## Requirements

- Ubuntu 18.04+ or compatible Linux
- Docker 20.10+
- Root access (sudo)
- At least 3GB free disk space (more for large `/home` on Engine)

## Security

- All snapshots encrypted with AES-256 (Restic)
- Config file `/opt/panelalpha/pasnap/.env-backup` mode `600`
- Database passwords via `MYSQL_PWD` (not CLI args)
- Store the encryption password offline — it cannot be recovered from the tool

## Support

1. [Troubleshooting](docs/troubleshooting.md)
2. Logs: `sudo tail -f /var/log/pasnap.log`
3. [GitHub Issues](https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/issues)

## License

See [LICENSE](LICENSE).
