# Changelog

All notable changes to PanelAlpha Snapshot Tool will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0/).

## [1.3.0] - 2026-07-17

### Breaking
- **Installation type names**: Detection now reports `multi-server`, `single-server`, or `engine` (replacing the old `app` / `engine` pair). Restic tags use `panelalpha-<type>-<hostname>`.
- **Unknown installation**: No silent fallback to Control Panel paths. If no supported layout is found, the tool exits with a clear error listing expected paths.

### Added
- **Single-server profile**: Detects `/opt/panelalpha/app-lite` together with `/opt/panelalpha/shared-hosting`. Snapshots include full engine data plus app-lite `.env`, `docker-compose.yml`, `data/api-storage`, and the panel database schema dumped from `database-core` (`DB_DATABASE` / `DB_USERNAME` / `DB_PASSWORD`).
- **`--quickstart`**: One command for install dependencies (if needed) + interactive setup (if unconfigured) + first snapshot.
- **Profile-driven snapshot/restore**: Shared helpers (`dump_mariadb_*`, `snapshot_docker_volume`, `snapshot_path`) replace duplicated engine/app branches.
- **Installation banner**: Every major command prints detected type and panel/engine paths.
- **Restore type mismatch warning**: Restoring a snapshot taken on a different installation type prompts for confirmation.
- **Post-setup database check**: `--setup` runs repository connectivity and `--verify-database` after saving config.
- **AES-256 reminder**: Setup wizard stresses that the Restic encryption password is required for any restore.
- **Admin 2FA snapshot diagnostics**: After dumping the panel database, the tool logs how many admins have confirmed 2FA and warns if `APP_KEY` is missing from snapshotted panel env (required to decrypt Fortify 2FA secrets after restore).

### Changed
- **Simplified codebase**: Rewritten around three declarative profiles; target size ~2.7k lines (was ~3.6k).
- **Fail-closed snapshots**: Missing critical database containers or required volumes abort the snapshot instead of reporting success with gaps.
- **Post-upload verification**: After `restic backup`, runs `restic check --read-data-subset=1/10` when available.
- **Setup defaults**: Suggested local path `/backup/panelalpha`, retention 30 days, hour 02:00.
- **Documentation**: Installation, usage, troubleshooting, and AGENTS updated for three installation types; Matomo references removed. Troubleshooting covers admin 2FA / `APP_KEY` after restore and `admin:disable-two-factor-authentication`.
- **`update_system_settings` timing**: On multi-server restore, host IP / trusted hosts are updated after the full stack is up, so changes apply to the final SQL-restored database.

### Fixed
- **Single-server blind spot**: Hosts with both `app-lite` and `shared-hosting` were previously classified as engine-only and skipped panel data.
- **Auto-update downgrade**: Version check now uses semver comparison and never replaces a newer local script with an older published release.
- **Empty AWS keys abort snapshot**: `validate_repository_config` no longer returns non-zero when S3 credentials are unset (broke local/SFTP backends under `set -e`).
- **Engine path**: Detection uses only `/opt/panelalpha/shared-hosting` (removed legacy `/opt/panelalpha/engine`).
- **Database restore integrity**: Restore no longer extracts `database-*-data` Docker volumes after SQL import. Those volume restores ran against a live MariaDB data directory and overwrote the consistent SQL dump (also wiping multi-server `update_system_settings` changes). MariaDB data is restored from SQL only; application volumes (`api-storage`, `redis-data`, `core-storage`) are still restored.

## [1.2.4] - 2026-07-15

### Fixed
- **MariaDB database images**: Backup, restore, and verification now auto-detect `mariadb` / `mariadb-dump` / `mariadb-admin` client binaries when `mysql` / `mysqldump` / `mysqladmin` are not present in the container (PanelAlpha multi-server MariaDB 12+ images)

### Changed
- **Troubleshooting documentation**: Manual database connection and restore examples now use `mariadb` (current images), with a note to use `mysql` on older MySQL-based images

## [1.2.3] - 2026-07-10

### Fixed
- **Database password parsing**: Environment file values are now read with `cut -f2-` so passwords containing `=` characters are no longer truncated
- **Database connection failures**: Improved password resolution with container environment fallback (`MYSQL_PASSWORD`) when `.env` is out of sync with the running database
- **MySQL command execution**: Database backup, restore, and verification now use `MYSQL_PWD` instead of passing passwords on the command line

### Added
- **`--verify-database` flag**: Diagnose database credential and connectivity issues without creating a snapshot
- **Actionable error messages**: Database connection errors now name the correct environment variable (`API_MYSQL_PASSWORD`, `CORE_MYSQL_PASSWORD`, etc.) and suggest diagnostic steps

### Changed
- **Troubleshooting documentation**: Expanded database backup failure guidance with per-installation password variable reference

## [1.2.2] - 2026-04-03

### Fixed
- **Engine wp-config.php content loss**: Fixed critical issue where snapshots for Engine installations could cause wp-config.php to lose database credentials by ensuring BOTH `.env` and `.env-core` files are backed up and restored together
- **Arithmetic operations with `set -e`**: Fixed 8 instances of `((var++))` causing script to exit when variable is 0, changed to safe `var=$((var + 1))` syntax
- **Division by zero in progress bar**: Fixed `show_progress()` function to handle `total=0` case that could cause arithmetic errors
- **Line endings**: Converted file from CRLF to LF (Unix) line endings

### Changed
- **Simplified update code**: Extracted duplicate curl/wget download logic into `download_and_apply_update()` helper function, reducing ~40 lines of duplicate code
- **Environment file handling**: Modified `create_config_snapshot()` to backup ALL environment files (`.env` and `.env-core`) if they exist
- **Environment file restoration**: Modified `restore_config()` to restore ALL environment files found in snapshot

### Added
- **Editor configuration**: Added `.editorconfig` file with project coding standards (UTF-8, LF line endings, 4-space indentation for shell scripts)
- **AI agent context**: Added `AGENTS.md` with comprehensive project context for AI agents
- **Skills documentation**: Added `skills/` directory with specialized skill modules

## [1.2.1] - 2026-01-14

### Added
- `--update` command to force an immediate update without prompts

### Fixed
- Prevented duplicate log entries when output is redirected to the same file as `LOG_FILE` (cron/nohup runs)
- Avoided false `/home` snapshot failures when rsync copies data but exits with non-zero status
- Improved `/home` snapshot fallback logic and rsync timeout/error messaging
- Normalized PATH for cron runs so Restic/Docker/rsync binaries are discoverable
- Enabled auto-update by default in non-interactive runs (cron) with opt-out via `PASNAP_DISABLE_AUTO_UPDATE=1` and support for `PASNAP_AUTO_UPDATE=1`

## [1.2.0] - 2025-11-19

### Added
- Engine configuration detection for `/opt/panelalpha/shared-hosting`
- Database dump progress monitoring
- Users database compression
- Engine `/home` and user container project backups
- Background snapshot creation (`--snapshot-bg`)
- Configurable snapshot timeouts via environment variables

### Changed
- Centralized configuration at `/opt/panelalpha/pasnap`
- Dynamic tagging based on application type

## [1.1.0] - 2025-11-10

### Added
- Multi-application support (Control Panel and Engine)
- Auto-update check

### Removed
- Matomo database backup (no longer part of PanelAlpha)

## [1.0.0] - 2025-10-01

### Added
- Initial release: Restic-based encrypted snapshots, local/SFTP/S3 backends, cron automation, restore
