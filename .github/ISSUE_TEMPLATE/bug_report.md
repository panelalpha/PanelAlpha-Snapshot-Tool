---
name: Bug Report
about: Create a report to help us improve
title: '[BUG] '
labels: bug
assignees: ''
---

## Bug Description

**Describe the bug**
A clear and concise description of what the bug is.

## To Reproduce

Steps to reproduce the behavior:
1. Run command '...'
2. Configure '...'
3. Execute '...'
4. See error '...'

**Command used:**
```bash
sudo ./pasnap.sh --option
```

## Expected Behavior

A clear and concise description of what you expected to happen.

## Actual Behavior

What actually happened instead.

## Environment

**System Information:**
- OS: [e.g., Ubuntu 22.04]
- Kernel: [e.g., 5.15.0-58-generic]
- Architecture: [e.g., x86_64]

**PanelAlpha:**
- Type: [Control Panel / Engine]
- Version: [e.g., 2.5.0]
- Installation Path: [e.g., /opt/panelalpha/app]

**Snapshot Tool:**
- Script Version: [e.g., 1.1.0]
- Installation Method: [Manual / Package]

**Docker:**
- Docker Version: [e.g., 24.0.5]
- Docker Compose Version: [e.g., 2.20.2]

**Dependencies:**
- Restic Version: [e.g., 0.16.0]
- jq Version: [e.g., 1.6]

**Storage Backend:**
- Type: [Local / SFTP / S3]
- Provider: [e.g., AWS, Hetzner, Local filesystem]
- Configuration: [Relevant non-sensitive config details]

## Logs

**Error Messages:**
```
Paste relevant error messages here
```

**Log Output:**
```bash
# From /var/log/pasnap.log (last 50 lines)
sudo tail -50 /var/log/pasnap.log
```

**Docker Logs (if applicable):**
```bash
# For database containers
docker logs database-api --tail 50
# or
docker logs database-core --tail 50
docker logs database-users --tail 50
```

## Configuration

**Configuration file (sensitive data removed):**
```bash
# From .env-backup (with passwords removed)
RESTIC_REPOSITORY="[REDACTED]"
BACKUP_RETENTION_DAYS=30
BACKUP_HOUR=2
```

## Screenshots

If applicable, add screenshots to help explain your problem.

## Additional Context

**What were you trying to achieve?**
- 

**Have you tried any workarounds?**
- 

**Does this happen consistently or intermittently?**
- 

**When did this start happening?**
- 

**Any recent changes to the system?**
- 

## Checklist

Before submitting, please check:

- [ ] I have searched for similar issues
- [ ] I have updated to the latest version
- [ ] I have included all relevant information
- [ ] I have removed sensitive data from logs/config
- [ ] I have tested with `--test-connection`
- [ ] I have checked system requirements
- [ ] I have reviewed the documentation

## Possible Solution

If you have suggestions on how to fix this bug, please describe them here.
