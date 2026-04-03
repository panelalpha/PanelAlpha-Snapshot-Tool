# PanelAlpha Snapshot Tool Skills

This directory contains specialized skills for AI agents working on the PanelAlpha Snapshot Tool project.

## Available Skills

### 1. Bash Scripting (`bash-scripting/`)
Core bash scripting patterns, error handling, and best practices specific to this project.

### 2. Docker Operations (`docker-operations/`)
Docker and Docker Compose operations for container management.

### 3. Database Management (`database-management/`)
MySQL/MariaDB operations for backup and restore procedures.

### 4. Restic Backup (`restic-backup/`)
Restic backup tool usage and repository management.

### 5. Testing & Validation (`testing-validation/`)
Testing procedures, validation scripts, and quality assurance.

## How to Use Skills

When working on this project, load the relevant skill(s) before making changes:

```bash
# Load a specific skill for detailed guidance
skill bash-scripting
skill docker-operations
skill database-management
skill restic-backup
skill testing-validation
```

## Skill Structure

Each skill directory contains:
- `SKILL.md` - Detailed instructions and examples
- `examples/` - Code examples and templates
- `troubleshooting/` - Common issues and solutions

## Quick Reference

| Skill | Use Case |
|-------|----------|
| `bash-scripting` | Writing/modifying shell functions, error handling |
| `docker-operations` | Container management, volume operations |
| `database-management` | MySQL dumps, imports, user management |
| `restic-backup` | Backup operations, repository management |
| `testing-validation` | Testing changes, validation procedures |

## Adding New Skills

To add a new skill:
1. Create a new directory under `skills/`
2. Add a `SKILL.md` file with detailed instructions
3. Add example files to `examples/` subdirectory
4. Update this README

## Skill Priority Levels

When multiple skills apply, use this priority:
1. **High**: bash-scripting (foundation for all work)
2. **Medium**: docker-operations, database-management (core functionality)
3. **Normal**: restic-backup, testing-validation (specialized operations)
