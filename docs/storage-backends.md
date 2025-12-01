# Storage Backends

PanelAlpha Snapshot Tool supports three types of storage backends for your snapshots.

## Local Storage

Store backups on the same server.

```bash
Repository type: local
Example: /backup/pasnap-snapshots
```

**Best for**: Development, testing, local backups

| Pros | Cons |
|------|------|
| Fast backup/restore | Single point of failure |
| Simple setup | Limited by local disk space |
| No network required | Lost if server fails |

### Configuration

```bash
RESTIC_REPOSITORY="/backup/pasnap-snapshots"
```

> ⚠️ **Warning**: If the server fails, you will lose your backups. Consider using remote storage for production environments.

---

## SFTP Storage

Store backups on a remote server via SSH.

```bash
Repository type: sftp
Example: sftp:backup-user@backup.example.com:/backups/panelalpha
```

**Best for**: Remote server backups, existing SSH infrastructure

| Pros | Cons |
|------|------|
| Secure (SSH encryption) | Requires SSH access setup |
| Widely supported | Depends on remote server availability |
| Off-site storage | Network latency |

### Configuration

```bash
RESTIC_REPOSITORY="sftp:user@hostname:/path/to/backups"
```

### SSH Key Setup

For passwordless authentication, set up SSH keys:

```bash
# Generate SSH key (if you don't have one)
ssh-keygen -t ed25519 -C "backup@panelalpha"

# Copy key to remote server
ssh-copy-id backup-user@backup.example.com
```

---

## S3-Compatible Storage

Store backups in cloud object storage.

```bash
Repository type: s3
Example: s3:s3.eu-west-1.amazonaws.com/my-bucket/pasnap-snapshots
```

**Supported providers**:
- AWS S3
- Hetzner Storage Box
- DigitalOcean Spaces
- MinIO
- Any S3-compatible storage

**Best for**: Production environments, scalable storage

| Pros | Cons |
|------|------|
| Highly available | Requires cloud account |
| Scalable | Ongoing costs |
| Geographically distributed | Network dependent |
| Cost-effective | Initial setup complexity |

### Configuration

```bash
RESTIC_REPOSITORY="s3:s3.eu-west-1.amazonaws.com/bucket-name/pasnap-snapshots"
AWS_ACCESS_KEY_ID="your-access-key"
AWS_SECRET_ACCESS_KEY="your-secret-key"
```

### Provider-Specific Examples

**AWS S3**:
```bash
RESTIC_REPOSITORY="s3:s3.eu-west-1.amazonaws.com/my-bucket/panelalpha"
```

**Hetzner Storage Box**:
```bash
RESTIC_REPOSITORY="s3:https://nbg1.your-objectstorage.com/bucket-name/panelalpha"
```

**DigitalOcean Spaces**:
```bash
RESTIC_REPOSITORY="s3:nyc3.digitaloceanspaces.com/my-space/panelalpha"
```

**MinIO (self-hosted)**:
```bash
RESTIC_REPOSITORY="s3:https://minio.example.com/bucket-name/panelalpha"
```

---

## Choosing a Backend

| Scenario | Recommended Backend |
|----------|-------------------|
| Development/Testing | Local |
| Small production, existing SSH infra | SFTP |
| Production, high availability needed | S3 |
| Compliance requirements | S3 with versioning |
| Budget-conscious | Local or self-hosted MinIO |

## Testing Connection

After configuration, always test your connection:

```bash
sudo ./pasnap.sh --test-connection
```
