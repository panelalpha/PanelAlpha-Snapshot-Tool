# PanelAlpha Snapshot Tool Documentation

Welcome to the PanelAlpha Snapshot Tool documentation. This tool provides a complete backup solution for PanelAlpha Control Panel and Engine installations.

## Table of Contents

- [Installation Guide](installation.md) - How to install and set up the tool
- [Storage Backends](storage-backends.md) - Configure local, SFTP, or S3 storage
- [Usage & Commands](usage.md) - Complete command reference
- [Server Migration](migration.md) - Move PanelAlpha to a new server
- [Configuration Reference](configuration.md) - All configuration options
- [Troubleshooting](troubleshooting.md) - Common issues and solutions

## Overview

### What Gets Backed Up

**PanelAlpha Control Panel** (`/opt/panelalpha/app`):
- API database (MySQL dump with routines and triggers)
- Matomo database
- `api-storage` volume
- `redis-data` volume
- Docker configuration files
- SSL certificates
- Nginx configurations

**PanelAlpha Engine** (`/opt/panelalpha/engine`):
- Core database
- Users databases
- `core-storage` volume
- Docker configuration files
- SSL certificates

### Supported Storage Backends

| Backend | Best For | Pros | Cons |
|---------|----------|------|------|
| Local | Development, testing | Fast, simple | Single point of failure |
| SFTP | Existing SSH infrastructure | Secure, widely supported | Requires SSH setup |
| S3 | Production environments | Highly available, scalable | Requires cloud account |

## Quick Links

- [GitHub Repository](https://github.com/panelalpha/PanelAlpha-Snapshot-Tool)
- [Report an Issue](https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/issues)
- [Changelog](../CHANGELOG.md)
