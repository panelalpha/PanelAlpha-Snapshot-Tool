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
├── pasnap.sh              # Main script (single distributable file)
├── README.md
├── CHANGELOG.md
├── AGENTS.md
└── docs/                  # User documentation
```

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

Shared helpers: `dump_mariadb_database`, `dump_mariadb_all`, `snapshot_docker_volume` (fail-closed when required), `snapshot_path`, `resolve_db_password` (env file argument), `dc` / `dc_container_id`.

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
bash -n pasnap.sh
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
