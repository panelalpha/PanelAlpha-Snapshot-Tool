# Changelog

All notable changes to PanelAlpha Snapshot Tool will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2025-11-10

### Added
- **Multi-application support**: Tool now supports both PanelAlpha Control Panel and PanelAlpha Engine
- **Automatic update checking**: Script checks for new versions from GitHub (main branch) once per day
- Automatic detection of application type (Control Panel vs Engine)
- Support for Engine databases: `database-core` and `database-users`
- Support for Engine volumes: `core-storage`, `database-core-data`, `database-users-data`
- Support for Engine configuration file: `.env-core`
- Application type information in snapshot metadata
- Application type display in `--version` command
- Backup creation before auto-update with timestamped filename
- Script restart with same arguments after successful update
- Environment variable `PASNAP_SKIP_UPDATE_CHECK=1` to disable update checks

### Changed
- **Script filename**: Changed from `panelalpha-snapshot.sh` to `pasnap.sh` for brevity
- `create_database_snapshot()`: Now handles both Control Panel (API only) and Engine (Core, Users) databases
- `restore_databases()`: Adapted to restore correct databases based on detected application type
- `verify_database_integrity()`: Validates appropriate databases for each application type
- `create_volumes_snapshot()`: Creates snapshots of correct volumes based on application type
- `restore_volumes()`: Restores appropriate volumes for detected application
- `wait_for_database_containers_enhanced()`: Works with single container (Control Panel) or dual containers (Engine)
- `clean_database_volumes()`: Cleans correct volumes based on application type
- `restore_config()`: Handles both `.env` (Control Panel) and `.env-core` (Engine) files
- `restore_single_database()`: Added support for `core` database user
- Snapshot metadata: Now includes application type and correct component lists
- Help text: Updated to mention support for both applications

### Removed
- **Matomo database support** (deprecated): Removed all Matomo database backup and restore functionality
- Removed `database-matomo` container handling
- Removed `database-matomo-data` volume from Control Panel backups
- Removed `matomo` volume from Control Panel backups
- Removed MATOMO_MYSQL_PASSWORD configuration references

### Fixed
- All hardcoded references to `.env` replaced with dynamic `$ENV_FILE` variable
- Database password extraction now uses correct environment file for each application type
- `update_system_settings()`: Now skipped for Engine (only applies to Control Panel)
- Control Panel now correctly handles single database container architecture

### Documentation
- README.md: Added section about automatic application type detection
- README.md: Updated introduction to mention support for both Control Panel and Engine
- README.md: Clarified which components are backed up for each application type
- Updated script header with new tool description
- README.md: Added download/installation section with three methods (git clone, wget release, direct download)

### Technical Details
- New constant: `PANELALPHA_APP_TYPE` (values: "engine", "app", or "unknown")
- New constant: `ENV_FILE` (points to `.env` or `.env-core` based on app type)
- New function: `check_for_updates()` - checks GitHub for newer versions
- Detection logic checks for `/opt/panelalpha/engine` and `/opt/panelalpha/app`
- Backward compatibility maintained: defaults to Control Panel if detection fails
- Control Panel volumes reduced to: `api-storage`, `database-api-data`, `redis-data`
- Update check runs once per 24 hours (cached in `/var/tmp/.pasnap_last_update_check`)
- Update download includes integrity verification before replacement
- Temporary directory naming changed from `panelalpha-snapshot-*` to `pasnap-snapshot-*`
- Log file path changed from `/var/log/panelalpha-snapshot.log` to `/var/log/pasnap.log`

## [1.0.0] - Previous release

### Features
- Complete backup and restore functionality for PanelAlpha Control Panel
- Support for local, SFTP, and S3 storage backends
- Automatic backup scheduling with cron
- Database snapshots with integrity verification (API database and Matomo database)
- Docker volume backups
- Configuration file backups
- Encrypted and incremental backups using Restic
- Retention policy management
- System settings update during restore

### Security
- Secure password handling
- File integrity verification
- Encrypted backups with AES-256
- Secure temporary file cleanup

---

[1.1.0]: https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/releases/tag/v1.0.0
