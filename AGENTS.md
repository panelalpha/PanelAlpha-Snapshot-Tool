# Agent Instructions for PanelAlpha Snapshot Tool

Context for AI agents working on the PanelAlpha Snapshot Tool (v1.3.0+).

## Project Overview

Standalone bash CLI for **host-level disaster recovery** of PanelAlpha using **Restic (AES-256)**. Not the same as per-site application backups in the Admin/Client Area.

### Key Technologies

- Bash (`set -euo pipefail`)
- Restic, Docker Compose, MariaDB client in containers (`mariadb` / `mariadb-dump`)

## Project Structure

```
pasnap-tool/
├── src/                   # Script source, one module per area; edit these
├── build.sh               # Joins src/[0-9][0-9]-*.sh into pasnap.sh (--check in CI)
├── pasnap.sh              # Built file users download; do not edit by hand
├── README.md
├── CHANGELOG.md
├── AGENTS.md
└── docs/                  # User documentation
```

`pasnap.sh` must stay one self-contained file: users `wget` it and installed copies
update themselves from `main/pasnap.sh`. Never make it source other files. After
editing `src/`, run `./build.sh` and commit both.

## Installation Detection (critical)

```bash
detect_installation() {
    # Priority:
    # 1. app-lite + shared-hosting → single-server
    # 2. shared-hosting            → engine
    # 3. app                       → multi-server
    # 4. else                      → unknown (fail via require_installation)
}
```

Globals: `INSTALLATION_TYPE`, `PANEL_DIR`, `ENGINE_DIR`. Engine always lives at `/opt/panelalpha/shared-hosting` (there is no `/opt/panelalpha/engine` install path).

**Never** fall back from `unknown` to multi-server paths.

## Profile Manifests

| Type | Snapshot scope |
|------|----------------|
| multi-server | `database-api` / panelalpha; volumes under `app`; `.env` + `.env-api`; packages; SSL |
| engine | core + users dumps; engine volumes; `.env` + `.env-core`; `users/`; `/home` |
| single-server | full engine + app-lite panel dump from `database-core` (`DB_*` from app-lite `.env` → `panelalpha-panel.sql`) + `config/panel/` + `data/api-storage` |

Shared helpers: `dump_mariadb_database`, `dump_mariadb_all`, `snapshot_docker_volume` (fail-closed when required), `snapshot_path`, `resolve_db_password` (env file argument), `verify_panel_2fa_snapshot`, `dc` / `dc_container_id`.

**Restore:** MariaDB data comes from SQL dumps only — do **not** restore `database-*-data` volumes after import (overrides SQL / corrupts live data dir). Application volumes (`api-storage`, `core-storage`) are restored. Multi Server `redis-data` is snapshotted but emptied on restore (it holds the job queue; replaying old jobs repeats their side effects). The root crontab is saved; restore adds back only lines with `/opt/panelalpha/` (not `pasnap.sh`). Engine `users/` is copied in full (`snapshot_path ... all`). Admin 2FA needs matching `APP_KEY` from snapshotted `.env-api` / `.env`. After panel config is restored, extend `SANCTUM_STATEFUL_DOMAINS` only when it already lists hosts (empty means the panel picks hosts per request; filling it breaks login on panel domains). Never overwrite `trusted_hosts` (installer default `*`). Restic lists snapshots oldest first: pick the newest with `sort_by(.time) | last`. Wait for MariaDB with `mariadb-admin --protocol=tcp -h 127.0.0.1 ping` (socket ping answers during image init).

Multi Server layout is the same from 0.9.1 to 1.9.8.6 (`database-api`, user `panelalpha`, `API_MYSQL_PASSWORD` in `.env`). Before 1.8.5 there is also `database-matomo` (user `matomo`, `MATOMO_MYSQL_PASSWORD`) and the `matomo` volume. nginx mounts `SSL_CERT_FULLCHAIN` / `SSL_CERT_PRIVKEY` from `.env` (installer default `./crt/server.*`).

## Environment Files

- Engine: always consider both `.env` and `.env-core`
- Multi-server: `.env` and `.env-api` for `API_MYSQL_PASSWORD`
- Single-server panel: `/opt/panelalpha/app-lite/.env` (`DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`)

## Arithmetic with `set -e`

```bash
# DON'T: ((var++))
# DO:
counter=$((counter + 1))
```

## Security

- Config: `/opt/panelalpha/pasnap/.env-backup` mode `600`
- Never log passwords; use `MYSQL_PWD` for MariaDB
- Restic password is mandatory for restore — surface that in UX

## Testing

```bash
./build.sh --check
# On real hosts: --verify-database, --snapshot, --list-snapshots per type
```

## Versioning

- `readonly SCRIPT_VERSION="x.x.x"` in `pasnap.sh`
- Update `CHANGELOG.md` and docs when behavior changes
- Semantic versioning

## Common Pitfalls

1. Forgetting single-server needs **both** stacks in snapshot and restore
2. Silent defaults for `unknown` (removed in 1.3.0)
3. Confusing this tool with product site backups
