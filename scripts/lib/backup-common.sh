#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
BACKUP_BASE_DIR="$PROJECT_DIR/backups"
LOCK_FILE="$BACKUP_BASE_DIR/.backup.lock"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  if [[ -n "${LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$msg" >> "$LOG_FILE"
  fi
}

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    log "ERROR: .env file not found at $ENV_FILE"
    exit 1
  fi

  set -a
  # shellcheck source=/dev/null
  # Remove UTF-8 BOM if present (common on Windows)
  source <(sed '1s/^\xEF\xBB\xBF//' "$ENV_FILE")
  set +a
}

get_stage() {
  local stage
  stage="$(printf '%s' "${STAGE:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

  case "$stage" in
    prod|dev|test)
      echo "$stage"
      ;;
    "")
      log "ERROR: STAGE not found in .env. Expected one of: prod, dev, test"
      exit 1
      ;;
    *)
      log "ERROR: Unsupported STAGE '$stage'. Expected one of: prod, dev, test"
      exit 1
      ;;
  esac
}

docker_compose_cmd() {
  local stage
  stage="$(get_stage)"
  echo "docker compose -f $PROJECT_DIR/docker-compose.yaml -f $PROJECT_DIR/stages/${stage}.yaml"
}

check_services_health() {
  local cmd
  cmd="$(docker_compose_cmd)"

  log "Checking services health..."
  local unhealthy
  unhealthy="$($cmd ps --format json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, dict): data = [data]
    for item in data:
        health = item.get("Health", "")
        state = item.get("State", "")
        if health == "unhealthy" or (state not in ("running", "")):
            print(item.get("Service", ""))
except: pass
' 2>/dev/null || true)"

  if [[ -n "$unhealthy" ]]; then
    log "WARNING: The following services are unhealthy or not running:"
    echo "$unhealthy" | while read -r svc; do
      log "  - $svc"
    done
    return 1
  fi

  log "All services are healthy."
  return 0
}

compute_checksum() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    log "ERROR: File not found for checksum: $file"
    exit 1
  fi
  sha256sum "$file" | awk '{print $1}'
}

create_manifest() {
  local backup_dir="$1"
  local manifest_file="$backup_dir/manifest.json"

  local timestamp
  timestamp="$(basename "$backup_dir")"

  if ! python3 - "$backup_dir" "$manifest_file" <<'PYEOF'
import json, os, hashlib, sys

backup_dir = sys.argv[1]
manifest_file = sys.argv[2]

try:
    with open(manifest_file) as fh:
        existing = json.load(fh)
    timestamp = existing.get('timestamp', os.path.basename(backup_dir))
    versions = existing.get('versions', {})
    source_host = existing.get('source_host', '')
except Exception:
    timestamp = os.path.basename(backup_dir)
    versions = {
        'camunda': os.environ.get('CAMUNDA_VERSION', ''),
        'elasticsearch': os.environ.get('ELASTIC_VERSION', ''),
        'keycloak': os.environ.get('KEYCLOAK_SERVER_VERSION', ''),
        'postgres': os.environ.get('POSTGRES_VERSION', ''),
    }
    source_host = os.environ.get('HOST', '')

manifest = {
    'timestamp': timestamp,
    'versions': versions,
    'source_host': source_host,
    'files': []
}

SKIP_NAMES = {'manifest.json', 'backup.log', 'restore.log'}

for root, dirs, files in os.walk(backup_dir):
    dirs.sort()
    for f in sorted(files):
        fpath = os.path.join(root, f)
        rel = os.path.relpath(fpath, backup_dir).replace(os.sep, '/')
        if rel in SKIP_NAMES:
            continue
        with open(fpath, 'rb') as fh:
            sha256 = hashlib.sha256(fh.read()).hexdigest()
        manifest['files'].append({'name': rel, 'sha256': sha256})

with open(manifest_file, 'w') as fh:
    json.dump(manifest, fh, indent=2)
PYEOF
  then
    log "ERROR: Failed to create manifest"
    exit 1
  fi
  log "Manifest created: $manifest_file"
}

verify_manifest() {
  local backup_dir="$1"
  local manifest_file="$backup_dir/manifest.json"

  if [[ ! -f "$manifest_file" ]]; then
    log "ERROR: Manifest not found: $manifest_file"
    exit 1
  fi

  if ! python3 - "$backup_dir" "$manifest_file" <<'PYEOF'
import json, os, hashlib, sys

backup_dir = sys.argv[1]
manifest_file = sys.argv[2]

try:
    with open(manifest_file) as f:
        manifest = json.load(f)
except json.JSONDecodeError:
    print('ERROR: Manifest is not valid JSON')
    sys.exit(1)

errors = 0
for entry in manifest.get('files', []):
    fname = entry['name']
    expected = entry['sha256']
    norm = fname.replace('/', os.sep)
    fpath = os.path.join(backup_dir, norm)

    if not os.path.isfile(fpath):
        print(f'ERROR: Missing file: {fname}')
        errors += 1
        continue

    with open(fpath, 'rb') as fh:
        actual = hashlib.sha256(fh.read()).hexdigest()

    if expected != actual:
        print(f'ERROR: Checksum mismatch for {fname}')
        errors += 1

if errors > 0:
    print(f'ERROR: Manifest verification failed with {errors} error(s)')
    sys.exit(1)
else:
    print('Manifest verification passed.')
PYEOF
  then
    log "ERROR: Manifest verification failed"
    exit 1
  fi
}

cleanup_old_backups() {
  local retention_days="${1:-7}"
  log "Cleaning up backups older than $retention_days days..."

  if [[ ! -d "$BACKUP_BASE_DIR" ]]; then
    log "Backup directory does not exist yet, nothing to clean."
    return 0
  fi

  local count=0
  while IFS= read -r dir; do
    log "Removing old backup: $dir"
    rm -rf "$dir"
    count=$((count + 1))
  done < <(find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -name "[0-9]*" -mtime +$retention_days 2>/dev/null || true)

  log "Removed $count old backup(s)."
}

acquire_lock() {
  mkdir -p "$BACKUP_BASE_DIR"

  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")"
    if kill -0 "$pid" 2>/dev/null; then
      log "ERROR: Another backup/restore process is already running (PID: $pid)"
      exit 2
    else
      log "WARNING: Stale lock file found, removing..."
      rm -f "$LOCK_FILE"
    fi
  fi

  echo "$$" > "$LOCK_FILE"
  log "Lock acquired: $LOCK_FILE"
}

release_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    rm -f "$LOCK_FILE"
    log "Lock released."
  fi
}

cleanup_on_error() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    log "ERROR: Script failed with exit code $exit_code"
  fi
  release_lock
  exit $exit_code
}

get_compose_project_name() {
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    printf '%s' "$COMPOSE_PROJECT_NAME" | tr '[:upper:]' '[:lower:]'
  else
    basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
  fi
}

compose_volume_name() {
  local volume_key="$1"
  echo "$(get_compose_project_name)_${volume_key}"
}

trap cleanup_on_error EXIT
