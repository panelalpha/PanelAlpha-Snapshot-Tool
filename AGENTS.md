# Agent Instructions for PanelAlpha Snapshot Tool

This file provides essential context for AI agents working on the PanelAlpha Snapshot Tool project.

## Project Overview

**PanelAlpha Snapshot Tool** is a bash-based backup and disaster recovery solution for PanelAlpha Control Panel and Engine. It uses Restic for secure, incremental backups and supports multiple storage backends (local, SFTP, S3).

### Key Technologies
- **Language**: Bash (shell scripting)
- **Backup Engine**: Restic
- **Containerization**: Docker & Docker Compose
- **Databases**: MySQL/MariaDB
- **Supported Platforms**: Ubuntu 18.04+, compatible Linux distributions

## Project Structure

```
/panelalpha-snapshoot-tool/
├── pasnap.sh              # Main script (3,400+ lines)
├── README.md              # Human-readable documentation
├── CHANGELOG.md           # Version history
├── CONTRIBUTING.md        # Contribution guidelines
├── LICENSE                # Apache 2.0 license
├── .editorconfig          # Editor configuration
├── mkdocs.yml             # Documentation site config
├── docs/                  # Documentation directory
│   ├── usage.md
│   ├── configuration.md
│   ├── migration.md
│   ├── storage-backends.md
│   └── troubleshooting.md
├── img/                   # Images and logos
└── .github/               # GitHub templates and workflows
    ├── workflows/
    ├── ISSUE_TEMPLATE/
    └── PULL_REQUEST_TEMPLATE.md
```

## Critical Code Patterns

### 1. Application Type Detection
The script auto-detects the PanelAlpha installation type:

```bash
detect_panelalpha_type() {
    if [[ -d "/opt/panelalpha/shared-hosting" && -f "/opt/panelalpha/shared-hosting/docker-compose.yml" ]]; then
        echo "engine"
    elif [[ -d "/opt/panelalpha/engine" && -f "/opt/panelalpha/engine/docker-compose.yml" ]]; then
        echo "engine"
    elif [[ -d "/opt/panelalpha/app" && -f "/opt/panelalpha/app/docker-compose.yml" ]]; then
        echo "app"
    else
        echo "unknown"
    fi
}
```

### 2. Environment File Handling
**CRITICAL**: Engine installations may have BOTH `.env` AND `.env-core` files. Always handle both:

```bash
# Environment files to always check
local env_files=(".env" ".env-core")
for env_file in "${env_files[@]}"; do
    if [[ -f "$env_file" ]]; then
        # Process file
    fi
done
```

### 3. Database Operations
The script handles two database types for Engine:
- **Core Database**: `database-core` service, user: `core`
- **Users Database**: `database-users` service, user: `root`

For Control Panel:
- **API Database**: `database-api` service, user: `panelalpha`

### 4. Arithmetic Operations
**IMPORTANT**: Due to `set -euo pipefail`, use this pattern:
```bash
# DON'T: ((var++)) - exits with code 1 when var is 0
# DO: var=$((var + 1))
counter=$((counter + 1))
```

### 5. Error Handling
All functions should handle errors gracefully:
```bash
if ! some_command; then
    log ERROR "Operation failed"
    return 1
fi
```

## Common Tasks

### Adding a New Storage Backend
1. Update `setup_config()` function (around line 993)
2. Add validation in `validate_repository_config()`
3. Update documentation in `docs/storage-backends.md`

### Modifying Database Backup Logic
1. Update `create_database_snapshot()` (around line 1229)
2. Update `restore_databases()` (around line 2649)
3. Test with both Engine and Control Panel configurations

### Adding New Configuration Options
1. Add to `setup_config()` interactive prompts
2. Update `load_configuration()` for defaults
3. Document in `docs/configuration.md`

## Testing Guidelines

### Syntax Check
```bash
bash -n pasnap.sh
```

### Test Scenarios
1. **Fresh install**: `--install` then `--setup`
2. **Snapshot creation**: `--snapshot`
3. **Restore**: `--restore latest`
4. **Cron setup**: `--cron install`

### Common Issues to Watch For
1. **Line endings**: Must be LF (Unix), not CRLF (Windows)
2. **Permissions**: Script must be executable
3. **Docker detection**: Both `docker-compose` and `docker compose` commands
4. **MySQL compatibility**: Works with both MySQL and MariaDB

## Security Considerations

1. **Password handling**: Never log passwords, use temp files for MySQL credentials
2. **File permissions**: Config files should be 600, directories 700
3. **Sensitive data**: Filtered from logs automatically

## Version Management

- Current version defined in `readonly SCRIPT_VERSION="x.x.x"`
- Update `CHANGELOG.md` with each change
- Follow semantic versioning (MAJOR.MINOR.PATCH)

## Documentation

- Update `docs/` files for user-facing changes
- Update `CHANGELOG.md` for all changes
- Keep `README.md` concise - detailed docs go in `docs/`

## Code Style

- Indentation: 4 spaces
- Line endings: LF (Unix)
- Encoding: UTF-8
- Max line length: ~120 characters (soft limit)

See `.editorconfig` for editor-specific settings.

## Common Pitfalls

1. **Forgetting Engine has two env files**: Always check both `.env` and `.env-core`
2. **Using `((var++))`**: Replace with `var=$((var + 1))`
3. **Not handling both docker compose syntaxes**: Support both `docker-compose` and `docker compose`
4. **Division by zero**: Always check for zero before division

## Resources

- **Main script**: `pasnap.sh` (3,400+ lines, thoroughly commented)
- **Documentation**: `docs/` directory
- **Changelog**: `CHANGELOG.md` (version history)
- **License**: Apache 2.0

## Contact

- Issues: https://github.com/panelalpha/PanelAlpha-Snapshot-Tool/issues/
- Website: https://panelalpha.com
- Documentation: https://panelalpha.com/documentation/
