# Backup & Restore

This document describes the backup and restore system for the Camunda 8 Self-Managed Docker Compose project.

## Contents

- [Data Sources](#data-sources)
- [Backup Scenarios](#backup-scenarios)
- [Restore Scenarios](#restore-scenarios)
- [CLI Reference](#cli-reference)
- [Troubleshooting](#troubleshooting)
- [Automation](#automation)

## Data Sources

The backup system secures the following data:

| Data Source | Method | Notes |
|-------------|--------|-------|
| Zeebe State | Volume dump (`orchestration.tar.gz`) | Cold backup (orchestration is stopped) |
| Elasticsearch | Snapshot API | FS repository via Docker volume `elastic-backup`, copied to host after snapshot |
| Keycloak DB | `pg_dump -Fc` | GZIP-compressed (`keycloak.sql.gz`) |
| Web Modeler DB | `pg_dump -Fc` | GZIP-compressed (`webmodeler.sql.gz`) |
| Configurations | `tar.gz` | `.env`, `connector-secrets.txt`, `Caddyfile`, `application.yaml` files |

**Not backed up:** `keycloak-theme` volume (initialized automatically by Identity).

## Backup Structure

Each backup creates a timestamped directory under `backups/YYYYMMDD_HHMMSS/`:

```
backups/20240115_120000/
├── backup.log              # Execution log
├── configs.tar.gz          # Configuration files
├── elasticsearch/          # Elasticsearch snapshot data
├── keycloak.sql.gz         # Keycloak database dump
├── manifest.json           # SHA256 checksums and metadata
├── orchestration.tar.gz    # Zeebe state volume dump
├── snapshot-info.json      # Elasticsearch snapshot metadata
└── webmodeler.sql.gz       # Web Modeler database dump
```

**Cross-platform compatibility:** Both `backup.sh` / `restore.sh` (Linux/macOS/WSL) and `backup.ps1` / `restore.ps1` (Windows) produce the **same directory structure and file formats**. Backups created on one platform can be restored on the other.

## Backup Scenarios

### Daily Backup (recommended)

Run the backup script regularly, e.g. via a cronjob:

```bash
./scripts/backup.sh
```

The script creates a backup folder under `backups/YYYYMMDD_HHMMSS/` and automatically generates a JSON manifest with checksums.

### Test Run (simulation)

To test the backup flow without modifying data:

```bash
./scripts/backup.sh --test
```

### Manual Backup

```bash
# Linux/macOS/WSL
./scripts/backup.sh

# Windows (PowerShell 7+)
.\scripts\backup.ps1
```

### Prerequisites

- The Camunda stack must be running
- `gzip` / `gunzip` must be available in your PATH:
  - **Linux/macOS**: Usually pre-installed
  - **Windows**: Install via Git for Windows, MSYS2, or Chocolatey (`choco install gzip`)
- **Windows only**: PowerShell 7+ (`pwsh`)

### Platform Notes

**Linux/macOS/WSL:** Use the `.sh` scripts
```bash
./scripts/backup.sh
./scripts/restore.sh backups/20240115_120000
```

**Windows:** Use the `.ps1` scripts
```powershell
.\scripts\backup.ps1
.\scripts\restore.ps1 backups\20240115_120000
```

### Elasticsearch Snapshot Architecture

Elasticsearch snapshots are stored in a dedicated Docker volume (`elastic-backup`) rather than a host bind-mount. This avoids permission issues on Windows Docker Desktop. After a successful snapshot, the data is copied from the volume to the host backup directory (`backups/YYYYMMDD_HHMMSS/elasticsearch/`). During restore, the data is copied back from the host into the Docker volume before the snapshot is restored.

## Restore Scenarios

### In-Place Restore (same cluster)

Restores all data on the same host, including configuration files:

```bash
./scripts/restore.sh backups/20240115_120000
```

**Warning:** This overwrites all current data! The script asks for confirmation.

### Cross-Cluster Restore

Restores data on a different cluster. Configuration files are **not** overwritten; instead they are extracted to `restored-configs/`:

```bash
./scripts/restore.sh --cross-cluster backups/20240115_120000
```

Requirements:
- Elasticsearch version in the backup must match `.env`
- Camunda version in the backup must match `.env`

### Test Restore (integrity check)

Checks backup integrity without restoring data:

```bash
./scripts/restore.sh --test backups/20240115_120000
```

### Dry-Run

Shows all steps that would be executed without actually running them:

```bash
./scripts/restore.sh --dry-run backups/20240115_120000
```

### Granular Restore

For granular restore (e.g. only one database), use the scripts as a template and execute individual steps manually:

```bash
# Keycloak DB only
zcat backups/20240115_120000/keycloak.sql.gz | docker exec -i postgres pg_restore -U bn_keycloak -d bitnami_keycloak

# Elasticsearch only
# Register snapshot repo and restore (see restore.sh)
```

## CLI Reference

### backup.sh / backup.ps1

| Option | Description |
|--------|-------------|
| `--test` | Simulates the backup flow without modifying data |
| `-h, --help` | Shows help |

### restore.sh / restore.ps1

| Option | Description |
|--------|-------------|
| `--force` | Skips all confirmation prompts |
| `--dry-run` | Shows what would be done without executing |
| `--cross-cluster` | Enables cross-cluster restore (no config overwrite) |
| `--test` | Checks backup integrity without restoring |
| `-h, --help` | Shows help |

### Examples

```bash
# Create backup
./scripts/backup.sh

# Test backup
./scripts/backup.sh --test

# Restore on same cluster
./scripts/restore.sh backups/20240115_120000

# Restore with automatic confirmation
./scripts/restore.sh --force backups/20240115_120000

# Cross-cluster restore
./scripts/restore.sh --cross-cluster backups/20240115_120000

# Dry-run of a restore
./scripts/restore.sh --dry-run --force backups/20240115_120000
```

## Troubleshooting

### "Another backup/restore process is already running"

A lock file (`backups/.backup.lock`) prevents parallel execution. If a previous crash left the lock behind:

```bash
rm backups/.backup.lock
```

### Elasticsearch snapshot fails

- Check if Elasticsearch is running: `curl http://localhost:9200/_cluster/health`
- Check if the Docker volume `elastic-backup` exists: `docker volume ls | grep elastic-backup`
- Check Elasticsearch logs: `docker compose logs elasticsearch`

**Note:** The backup system uses a Docker volume (`elastic-backup`) instead of a host bind-mount to avoid permission issues on Windows Docker Desktop. Snapshot data is copied from the volume to the host backup directory after a successful snapshot. During restore, data is copied back from the host into the volume before registration.

### Zeebe state backup fails with Docker EOF

The backup script retries the Zeebe volume backup up to 3 times with 5-second delays. If it still fails:
- Check Docker Desktop is running
- Check the `orchestration` volume exists: `docker volume ls | grep orchestration`
- Try manually: `docker run --rm -v orchestration:/data -v "$(pwd)/backups:/backup" alpine tar czf /backup/orchestration.tar.gz -C /data .`

### pg_restore warnings

`pg_restore` often emits warnings about existing objects. This is normal and does not affect the restore as long as no errors occur.

### Orchestration does not start after restore

- Check if the Zeebe state archive is valid: `tar tzf backups/.../orchestration.tar.gz`
- Check permissions in the volume after restore

### Version mismatch on cross-cluster restore

Ensure that versions in `.env` match the backup:

```bash
# Show version from backup
cat backups/20240115_120000/manifest.json | jq '.versions'
```

### Manifest verification failed

The manifest contains SHA256 checksums of all backup files. On failure:
- Check if files are missing or corrupted in the backup folder
- Check available disk space

## Automation

### Cronjob for daily backups

Add the following line to your crontab (`crontab -e`):

```cron
# Daily Camunda backup at 2:00 AM
0 2 * * * cd /path/to/camunda8_caddy && ./scripts/backup.sh >> backups/cron.log 2>&1
```

### Windows Task Scheduler (PowerShell)

Create a task that runs `scripts/backup.ps1` daily:

```powershell
$action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-File C:\path\to\scripts\backup.ps1" -WorkingDirectory "C:\path\to\camunda8_caddy"
$trigger = New-ScheduledTaskTrigger -Daily -At "02:00"
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "CamundaBackup" -Description "Daily Camunda 8 Backup"
```

### Backup Retention

By default, backups older than 7 days are automatically deleted. This can be adjusted in the script `scripts/lib/backup-common.sh` (or `.ps1`) via the `Cleanup-OldBackups` / `cleanup_old_backups` parameter.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error |
| 2 | Already running (lock conflict) |
