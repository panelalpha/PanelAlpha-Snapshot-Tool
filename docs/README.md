# PanelAlpha Snapshot Tool Documentation

Welcome to the PanelAlpha Snapshot Tool documentation. This tool provides encrypted disaster-recovery snapshots for PanelAlpha hosts.

## Table of Contents

- [Installation Guide](installation.md) — Install and set up the tool
- [Storage Backends](storage-backends.md) — Local, SFTP, or S3 storage
- [Usage & Commands](usage.md) — Command reference
- [Server Migration](migration.md) — Move PanelAlpha to a new server
- [Configuration Reference](configuration.md) — Configuration options
- [Troubleshooting](troubleshooting.md) — Common issues and solutions

## Overview

### Installation types (auto-detected)

| Type | Detected when | What is snapshotted |
|------|---------------|---------------------|
| **multi-server** | `/opt/panelalpha/app/docker-compose.yml` | API DB, `api-storage` / `database-api-data` / `redis-data`, panel config (`.env`, `.env-api`), packages, SSL |
| **single-server** | `app-lite` **and** `shared-hosting` | Full engine scope **plus** app-lite panel DB (schema in `database-core`), `.env`, compose, `data/api-storage` |
| **engine** | `shared-hosting` without app-lite | Core + users DBs, engine volumes, `.env` / `.env-core`, `users/`, `/home`, SSL |

If none of these layouts is found, the tool exits with an error (no silent fallback).

### Supported storage backends

| Backend | Best for | Notes |
|---------|----------|--------|
| Local | Labs / same-host DR | Suggest `/backup/panelalpha`; lost if the server dies |
| SFTP | Existing SSH infra | Needs passwordless SSH for root |
| S3 | Production offsite | AWS, Hetzner, MinIO, DigitalOcean Spaces |

All backends use **Restic AES-256** encryption. Keep `RESTIC_PASSWORD` safe.

## Quick Links

- [GitHub Repository](https://github.com/panelalpha/PanelAlpha-Snapshot-Tool)
- [Report an Issue](https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/issues)
- [Changelog](../CHANGELOG.md)
