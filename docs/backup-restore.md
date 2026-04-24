# Backup & Restore

This document describes the backup and restore system for the Camunda 8 Self-Managed Docker Compose project.

## Contents

- [Data Sources](#data-sources)
- [Relation to Official Procedure](#relation-to-official-procedure)
- [Users and Permissions](#users-and-permissions)
- [Backup Scenarios](#backup-scenarios)
- [Restore Scenarios](#restore-scenarios)
- [Pre/Post-Restore State Comparison](#prepost-restore-state-comparison)
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

**Volume naming:** Docker Compose prefixes managed volume names with the compose project name (for example `camundacomposenvl_orchestration`). The scripts derive the correct prefixed volume names automatically. The Elasticsearch snapshot repository volume is exempt because it is explicitly named `elastic-backup`.

## Relation to Official Procedure

These scripts implement a **cold backup** tailored to the local Docker Compose stack: the `orchestration` container is stopped, then Elasticsearch is snapshotted, PostgreSQL databases are dumped, and the Zeebe state volume is archived. This yields consistent backups without orchestrating Camunda's backup APIs, at the cost of a short downtime window for the duration of the backup.

They do **not** implement the official Camunda 8 Self-Managed hot-backup procedure, which:

- Keeps Zeebe running under a soft export pause
- Uses Camunda actuator endpoints (`/actuator/backupHistory`, `/actuator/backupRuntime`, `/actuator/backups`) to coordinate component backups
- Snapshots only `zeebe-record*` at the Elasticsearch layer (with `"feature_states": ["none"]`)
- Requires each component (Operate, Tasklist, Optimize, Zeebe broker) to be configured with a backup repository

For zero-downtime production backups, follow the official guides:

- Backup: https://docs.camunda.io/docs/self-managed/operational-guides/backup-restore/elasticsearch/es-backup/
- Restore: https://docs.camunda.io/docs/self-managed/operational-guides/backup-restore/elasticsearch/es-restore/

The default `.orchestration/application.yaml` in this project does not expose the backup actuator endpoints and does not configure backup storage for Operate/Tasklist/Optimize/Zeebe. Adopting the official procedure requires those configuration changes first.

Alignment notes:

- The Elasticsearch snapshot repository registration and the `path.repo` mount in `docker-compose.yaml` match the official procedure and can be reused if you switch approaches later.
- The snapshot `PUT` body uses `"feature_states": ["none"]`, matching the official recommendation for Elasticsearch 8.x.
- On restore, the scripts delete only Camunda-related indices and data streams (`operate*`, `tasklist*`, `optimize*`, `zeebe*`, `camunda-*`, `.camunda*`, `.tasks*`) rather than wiping the whole cluster, which matches the index filter example in the official restore docs.
- Before deleting anything on restore, the scripts verify the named snapshot exists in the repository and abort otherwise. A wrong or incomplete backup directory cannot destroy live data.

## Users and Permissions

Users and authorizations created via `scripts/add-camunda-user.sh` / `scripts/add-camunda-user.ps1` are fully covered by backup and restore. The script writes to two stores, and both are captured:

| What the user script creates | Where it's stored | Captured by |
|---|---|---|
| Keycloak user (credentials, email, first/last name) | `postgres` container, database `bitnami_keycloak` | `pg_dump` → `keycloak.sql.gz` |
| Realm role mappings (`Default user role`, `Orchestration`, `Optimize`, `Web Modeler`, `Console`, `ManagementIdentity`, `Web Modeler Admin`) | Same Keycloak database | Same `pg_dump` |
| Camunda internal role assignment (`admin` or `readonly-admin`, via `PUT /v2/roles/{role}/users/{user}`) | Zeebe log → Elasticsearch `camunda-*` indices (via `CamundaExporter` configured in `.orchestration/application.yaml`) | `orchestration.tar.gz` volume dump + Elasticsearch snapshot |

On restore, the Keycloak database is restored via `pg_restore --clean --if-exists`, the Zeebe state is restored from the volume archive, and the Elasticsearch snapshot restore recreates the `camunda-*` indices that hold the authorization records (the restore's targeted delete includes the `camunda-` prefix so stale records are wiped before the snapshot is restored).

**Important timing caveat:** a backup reflects state at the moment it was taken. If you run `add-camunda-user.sh` *after* a backup and then restore that backup, the new user is lost. If you want new users preserved, take a fresh backup immediately after creating them.

**Quick verification after creating a new admin:**

```bash
# Confirm Camunda authorization indices exist
curl -s http://localhost:9200/_cat/indices?h=index | grep -E '^(camunda-|operate-|tasklist-)'

# Take a backup
./scripts/backup.sh

# Confirm the camunda-* indices are in the snapshot
jq -r '.snapshots[0].indices[]' backups/<timestamp>/snapshot-info.json | grep camunda
```

## Backup Structure

Each backup creates a timestamped directory under `backups/YYYYMMDD_HHMMSS/`:

```
backups/20240115_120000/
├── backup-state.json      # pre-backup Elasticsearch state summary
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

Each real backup also writes `backup-state.json` before `orchestration` is stopped. It captures the current Elasticsearch cluster health, Camunda index counts, document totals, and data stream names so later debugging can compare what was present at backup time.

The manifest is recursive. It covers both top-level backup files, `backup-state.json`, and nested files under `elasticsearch/`, so `--test` restore mode validates copied snapshot data as well.

### Test Run (simulation)

To test the backup flow without modifying data:

```bash
./scripts/backup.sh --test
```

`--test` verifies prerequisites and logs the steps that would run, but it does not stop orchestration, dump volumes, create a manifest, or write a retained backup.

### Manual Backup

```bash
# Linux/macOS/WSL
./scripts/backup.sh

# Windows (PowerShell 7+)
.\scripts\backup.ps1
```

### Prerequisites

- The Camunda stack must be running
- **Linux/macOS/WSL** (`.sh` scripts):
  - `gunzip`, `python3`, `curl`, `tar`, and `docker compose` must be available in your PATH
  - `gunzip` and `tar` are usually pre-installed
- **Windows only** (`.ps1` scripts):
  - PowerShell 7+ (`pwsh`)
  - `gzip` must be available in your PATH
  - install via Git for Windows, MSYS2, or Chocolatey (`choco install gzip`)

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

The `elastic-backup` volume has a fixed Docker `name:` and is intentionally not removed during restore. The restore flow overwrites its contents from the selected backup instead.

## Restore Scenarios

### In-Place Restore (same cluster)

Restores all data on the same host, including configuration files:

```bash
./scripts/restore.sh backups/20240115_120000
```

**Warning:** This overwrites all current data! The script asks for confirmation.

By default, restore does **not** create a fresh backup first. To trigger one with the existing backup script before restore starts, add `--createBackup`. The pre-restore backup log is written to `backups/pre-restore-backup.log`. If that pre-backup fails, restore continues with a warning.

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

`--test` validates the manifest and checksum set only. It does not stop the stack or modify data.

### Dry-Run

Shows all steps that would be executed without actually running them:

```bash
./scripts/restore.sh --dry-run backups/20240115_120000
```

### Restore Order

The restore scripts intentionally do **not** start the full Camunda stack immediately.

Current restore flow:

1. Stop the stack and remove the data volumes (`orchestration`, `elastic`, `postgres`, `postgres-web`)
2. Start only the core services needed for restore: `postgres`, `web-modeler-db`, `elasticsearch`
3. Restore the PostgreSQL databases, then run `ANALYZE` on each restored database so the planner has fresh statistics before app services start (without this, the first Web Modeler project load after restore can take ~12 s per query until autovacuum catches up)
4. Restore the Elasticsearch snapshot while Camunda application services are still stopped
5. Create the `orchestration` container via Docker Compose and restore Zeebe state into the compose-managed volume
6. Restore configuration files
7. Start the full stack and wait for service health checks
8. Remove restore-created dangling Compose volumes from older runs

This ordering prevents Camunda services from recreating Elasticsearch indices before the snapshot restore runs.

The restore shutdown step now uses `docker compose down --remove-orphans`. After the stack is healthy again, the scripts remove dangling volumes that still carry this Compose project's labels and were created before the current restore started. This clears orphaned anonymous volumes from prior restore runs without touching parallel stacks or the fixed `elastic-backup` volume.

### Granular Restore

For granular restore (e.g. only one database), use the scripts as a template and execute individual steps manually:

```bash
# Keycloak DB only
zcat backups/20240115_120000/keycloak.sql.gz | docker exec -i postgres pg_restore -U bn_keycloak -d bitnami_keycloak

# Elasticsearch only
# Register snapshot repo and restore (see restore.sh)
```

## Pre/Post-Restore State Comparison

Every real restore (not `--dry-run`, not `--test`) captures a snapshot of the current Elasticsearch state **before** any destructive step, runs the restore, and then captures the state **again** after the stack is healthy. A comparison is logged and both snapshots are written next to the backup:

```
backups/20240115_120000/
├── restore-state-before.json   # pre-restore Elasticsearch state
└── restore-state-after.json    # post-restore Elasticsearch state
```

Each state file contains:

- `reachable` — whether Elasticsearch answered at `http://localhost:9200` within the timeout
- `cluster` — cluster name, status (`green`/`yellow`/`red`), node count, active shard count
- `indices` — Camunda-related indices only (matching `^(operate|tasklist|optimize|zeebe|camunda-|\.camunda|\.tasks)`), each with name, doc count, and on-disk size
- `data_streams` — Camunda-related data streams
- `component_counts` — per-component index count (`operate`, `tasklist`, `optimize`, `zeebe`, `camunda`, `other`)
- `total_camunda_indices`, `total_camunda_docs` — aggregated totals

The comparison emitted to `restore.log` and stdout looks like:

```
=== Elasticsearch state comparison (before -> after) ===
  Connectivity:    reachable -> reachable
  Cluster status:  green -> green
  Camunda indices: 42 -> 42
  Camunda docs:    15387 -> 15387
    operate   12 -> 12
    tasklist  8  -> 8
    ...
  Indices removed (0):
  Indices added (0):
  Indices with doc count changes (0):
========================================================
```

Use this as a quick sanity check that the restore landed the expected data. Non-Camunda indices are intentionally excluded — the restore itself only touches Camunda-scoped data, so noise from other indices would drown out the signal. State files are skipped by the manifest and do not affect backup integrity checks.

`backup-state.json` uses the same schema as the restore state files, but records the cluster state at backup time and is included in the manifest.

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
| `--createBackup` | Runs the existing backup script before restore starts |
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

# Restore on same cluster after creating a fresh backup first
./scripts/restore.sh --createBackup backups/20240115_120000

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

Current scripts also release the lock reliably on PowerShell via `try/finally`, and the bash backup script restarts `orchestration` from its EXIT trap if a failure happens after the cold-backup stop.

### Elasticsearch snapshot fails

- Check if Elasticsearch is running: `curl http://localhost:9200/_cluster/health`
- Check if the Docker volume `elastic-backup` exists: `docker volume ls | grep elastic-backup`
- Check Elasticsearch logs: `docker compose logs elasticsearch`

**Note:** The backup system uses a Docker volume (`elastic-backup`) instead of a host bind-mount to avoid permission issues on Windows Docker Desktop. Snapshot data is copied from the volume to the host backup directory after a successful snapshot. During restore, data is copied back from the host into the volume before registration.

If restore fails with a message like `cannot restore index ... because an open index with same name already exists in the cluster`, it usually means application services recreated indices before the snapshot restore. Current scripts avoid this by restoring Elasticsearch before starting the full Camunda stack.

### Zeebe state backup fails with Docker EOF

The backup script retries the Zeebe volume backup up to 3 times with 5-second delays. If it still fails:
- Check Docker Desktop is running
- Check the compose-prefixed orchestration volume exists: `docker volume ls | grep orchestration`
- Try manually with the actual volume name from `docker volume ls`, for example: `docker run --rm -v camundacomposenvl_orchestration:/data -v "$(pwd)/backups:/backup" alpine tar czf /backup/orchestration.tar.gz -C /data .`

If all 3 retries fail, the backup exits with status `1`. It no longer falls through as a partial success.

### Backup says the stack is not running

The backup scripts now count running containers instead of trusting `docker compose ps` exit status. If you see:

`Stack is not running (0 containers running).`

start the stack first and verify at least one service is in `running` state:

```bash
docker compose ps --filter status=running
```

### Config archive warnings

Configuration backup now distinguishes between:
- No matching config files found: the backup logs a warning and skips `configs.tar.gz`
- `tar` returned a non-zero exit code: the backup logs that the archive may be incomplete

Do not treat `Configs backed up ... (N files)` and `WARNING: Config archive may be incomplete` as equivalent outcomes.

### pg_restore warnings

`pg_restore` often emits warnings about existing objects. This is normal and does not affect the restore as long as no errors occur.

### Web Modeler is slow for ~30 s after restore

**Symptom:** Opening a BPMN diagram right after a restore takes ~20 s instead of ~2 s. Browser DevTools shows `GET /internal-api/projects/{id}?includeFiles=true&includeFolders=true` spending ~12 s in TTFB, while the same endpoint with `includeFolders=false` returns in ~200 ms. After ~30 s of activity, every request becomes fast again without any intervention.

**Cause:** `pg_dump -Fc` / `pg_restore` does **not** restore the contents of `pg_statistic` — PostgreSQL's per-column planner statistics are always rebuilt locally after restore. Until they exist, the planner falls back to hard-coded defaults and picks poor plans for any non-trivial query (the Web Modeler project-with-folders fetch is particularly sensitive because it joins across projects, folders, and files). Autovacuum eventually runs `ANALYZE` on its own schedule (~30 s on the default configuration), which is why the slowness disappears after a brief window.

This is an inherent `pg_restore` behavior, not a bug in the Camunda images or in the backup format. It affects **both** `postgres` (Keycloak) and `web-modeler-db`, but the Web Modeler queries are the ones most visibly affected.

**Fix:** The restore scripts now run `ANALYZE` on each database immediately after `pg_restore` finishes and before the Camunda application services are started. With fresh statistics in place from the first request, the planner chooses the correct plan and the first BPMN load after restore matches normal cold-start performance.

If you ever run a manual `pg_restore` (see [Granular Restore](#granular-restore)), remember to follow up with:

```bash
docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "ANALYZE;"
docker exec web-modeler-db psql -U "$WEBMODELER_DB_USER" -d "$WEBMODELER_DB_NAME" -c "ANALYZE;"
```

Without it the stack still works correctly — it is only slow until autovacuum catches up.

### Orchestration does not start after restore

- Check if the Zeebe state archive is valid: `tar tzf backups/.../orchestration.tar.gz`
- Check permissions in the volume after restore

### "volume ... already exists but was not created by Docker Compose"

This warning is about Docker Compose ownership metadata, not necessarily broken data.

It appears when a named volume exists but was created by plain `docker run` instead of `docker compose`, so Compose sees a usable volume without its usual labels.

Current restore scripts avoid this for the `orchestration` volume by explicitly creating the container with Compose before restoring Zeebe state into the volume.

If you still see the warning for an old restored stack but the services are healthy, it is usually safe to leave it alone until the next restore or planned maintenance window.

### Version mismatch on cross-cluster restore

Ensure that versions in `.env` match the backup:

```bash
# Show version from backup
python3 -c "import json; d=json.load(open('backups/20240115_120000/manifest.json')); print(d.get('versions',{}))"
```

### Manifest verification failed

The manifest contains SHA256 checksums of all backup files, including nested files under `elasticsearch/`. On failure:
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
