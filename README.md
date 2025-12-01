<div align="center">
  <img src="img/logo.svg" alt="PanelAlpha Snapshot Tool" width="100"/>
  <h1>PanelAlpha Snapshot Tool</h1>
  <h3>Secure Snapshots for PanelAlpha</h3>

  <a href="https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/releases"><img alt="GitHub release" src="https://img.shields.io/github/v/release/panelalpha/PanelAlpha-Snapshot-Tool"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/panelalpha/PanelAlpha-Snapshot-Tool"></a>

</div>

## Intro & motivation

**PanelAlpha Snapshot Tool is a self-hosted backup solution to create, store, and restore complete snapshots of your PanelAlpha installation.**

The objective is to provide a reliable way to backup your PanelAlpha Control Panel or Engine, including databases, Docker volumes, configuration files, and SSL certificates. Snapshots can be stored locally, on remote servers via SFTP, or in S3-compatible cloud storage.

The tool automatically detects your installation type (Control Panel or Engine) and handles everything accordingly - no manual configuration needed.

## Features

- 📸 Create complete snapshots of databases, volumes, and configuration files.
- 🔄 Restore snapshots on the same server or migrate to a new one.
- ☁️ Store backups locally, via SFTP, or in S3-compatible storage (AWS, Hetzner, DigitalOcean).
- 🤖 Schedule automatic daily backups with built-in cron management.
- 🔐 AES-256 encryption for all snapshots.
- 🎯 Auto-detection of PanelAlpha Control Panel or Engine installation.
- 📋 Simple CLI interface with interactive setup wizard.

## Installation

1. Download the script:
```bash
wget -O /opt/panelalpha/pasnap.sh https://raw.githubusercontent.com/panelalpha/PanelAlpha-Snapshot-Tool/main/pasnap.sh
```

2. Install dependencies:
```bash
sudo /opt/panelalpha/pasnap.sh --install
```

For detailed installation and configuration instructions, see the [Documentation](docs/README.md).

## Quick Start

```bash
# Configure storage backend
sudo ./pasnap.sh --setup

# Test connection
sudo ./pasnap.sh --test-connection

# Create your first snapshot
sudo ./pasnap.sh --snapshot

# Enable automatic daily backups
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
- At least 3GB free disk space

## Security

- All snapshots are encrypted using AES-256
- Configuration files have restricted permissions (600)
- HTTPS/TLS for all remote communications
- S3 credentials are only exported during operations

## Support

If you encounter issues:

1. Check the [Troubleshooting Guide](docs/troubleshooting.md)
2. Review logs: `sudo tail -f /var/log/pasnap.log`
3. Open an [Issue](https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/issues)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
