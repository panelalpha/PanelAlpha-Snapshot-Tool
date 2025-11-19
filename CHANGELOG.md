# Changelog

All notable changes to PanelAlpha Snapshot Tool will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2025-11-19

### Added
- **Engine configuration detection**: Support for `/opt/panelalpha/shared-hosting` directory detection alongside `/opt/panelalpha/engine`
- **Database dump progress monitoring**: New `monitor_dump_progress()` function for real-time progress tracking during database dumps
- **Users database compression**: Automatic compression support for Users database dumps with fallback to uncompressed if compression fails
- **Engine home directory backup**: Snapshot of `/home` directory for Engine deployments
- **Engine user container projects backup**: Snapshot of user container projects directory for Engine deployments
- **Restore functions for Engine data**: `restore_users()` and `restore_home_directory()` functions for Engine-specific restore operations
- **Volume snapshot progress tracking**: Real-time progress monitoring during Docker volume snapshots with error reporting
- **Configuration migration**: Automatic migration of `.env-backup` files from old location to new centralized `/opt/panelalpha/pasnap` directory
- **Background snapshot creation**: New `--snapshot-bg` parameter to create snapshots in background, survives terminal closure with `nohup` and `disown`
- **Configurable snapshot timeouts**: New environment variables to adjust timeouts for large volumes/directories:
  - `PASNAP_VOLUME_SNAPSHOT_TIMEOUT` for Docker volumes
  - `PASNAP_USERS_HOME_SNAPSHOT_TIMEOUT` for user containers and `/home` directory

### Changed
- **Configuration path management**: Centralized configuration directory at `/opt/panelalpha/pasnap` with migration support
- **Environment file detection**: Enhanced logic to detect `.env` or `.env-core` based on file existence
- **Database dump execution**: Now runs in background with progress monitoring for both Core and Users databases
- **Volume snapshot creation**: Improved error handling for volume snapshots with better diagnostics for permission and disk space issues
- **Database import**: Updated Users database restore to support both compressed (`.gz`) and uncompressed formats
- **Snapshot tagging**: Dynamic tagging based on application type (added "users" and "home" tags for Engine deployments)
- **Snapshot metadata**: Enhanced metadata generation with proper component listing based on application type
- **Error handling**: Better error detection for tar operations with specific handling for database files that change during backup

### Fixed
- **Configuration directory creation**: Fixed missing configuration directory creation in `setup_config()` function
- **Volume snapshot error codes**: Changed success evaluation from exit code to actual file creation - properly handle tar exit code 1 (file changed during archive) for database volumes by checking if snapshot file exists and has content
- **Database dump timeout**: Use configurable timeouts (`CORE_DUMP_TIMEOUT`, `USERS_DUMP_TIMEOUT`) instead of hardcoded values
- **Volume snapshot timeout**: Added configurable timeout for large volumes via `PASNAP_VOLUME_SNAPSHOT_TIMEOUT` env var (default 7200s) - prevents premature timeout for large volumes
- **User/home snapshot timeout**: Added configurable timeout for user containers and `/home` snapshots via `PASNAP_USERS_HOME_SNAPSHOT_TIMEOUT` env var (default 14400s)
- **rsync timeout handling**: Added timeout protection to `rsync` commands for user containers and `/home` snapshots to prevent hanging
- **Environment file restoration**: Fixed legacy `.env-core` backup detection and restoration for Engine deployments
- **Snapshot ID extraction**: Improved snapshot ID extraction using jq with better null handling
- **rsync error handling**: Fixed false error reporting for `/home` and user container snapshots - now properly checks file creation instead of rsync exit code (handles exit codes 23, 24 for partial transfers due to permission differences)
- **Volume snapshot error details**: Improved error message reporting when tar output file is unavailable
- **Volume snapshot file validation**: Added minimum size check (1KB) to prevent incomplete tar files from being marked as successful
- **rsync fallback mechanism**: Added automatic fallback to `cp` if rsync fails or returns non-zero exit code for both user containers and `/home` snapshots
- **rsync exit code handling**: Properly handle exit codes 0, 23, 24 from rsync as acceptable (partial transfers are normal for files changing during backup)
- **User container snapshot reliability**: Improved robustness by checking for actual file creation instead of relying on command exit status

### Technical Details
- New configuration directory: `/opt/panelalpha/pasnap` with automatic migration from old location
- Enhanced `detect_panelalpha_type()`: Now checks for `/opt/panelalpha/shared-hosting` first
- Improved database password extraction: Now checks both `.env` and `.env-core` files
- Volume snapshot debugging: Displays volume size before backup
- Database compression: Gzip compression applied to Users database with fallback mechanism

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

[1.1.1]: https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/releases/tag/v1.0.0
