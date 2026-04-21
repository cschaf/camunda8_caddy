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
  unhealthy="$($cmd ps --format json 2>/dev/null | jq -r '.[] | select(.Health == "unhealthy" or (.State != "running" and .State != "")) | .Service' 2>/dev/null || true)"

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

  load_env

  local timestamp
  timestamp="$(basename "$backup_dir")"

  local json='{}'
  json="$(echo "$json" | jq \
    --arg timestamp "$timestamp" \
    --arg camunda_version "${CAMUNDA_VERSION:-}" \
    --arg elastic_version "${ELASTIC_VERSION:-}" \
    --arg keycloak_version "${KEYCLOAK_SERVER_VERSION:-}" \
    --arg postgres_version "${POSTGRES_VERSION:-}" \
    --arg host "${HOST:-}" \
    '.timestamp = $timestamp | .versions.camunda = $camunda_version | .versions.elasticsearch = $elastic_version | .versions.keycloak = $keycloak_version | .versions.postgres = $postgres_version | .source_host = $host' \
  )"

  local files_json="[]"
  for f in "$backup_dir"/*; do
    [[ -f "$f" ]] || continue
    local fname
    fname="$(basename "$f")"
    [[ "$fname" == "manifest.json" ]] && continue

    local checksum
    checksum="$(compute_checksum "$f")"
    files_json="$(echo "$files_json" | jq \
      --arg name "$fname" \
      --arg checksum "$checksum" \
      '. + [{name: $name, sha256: $checksum}]' \
    )"
  done

  json="$(echo "$json" | jq --argjson files "$files_json" '.files = $files')"
  echo "$json" > "$manifest_file"
  log "Manifest created: $manifest_file"
}

verify_manifest() {
  local backup_dir="$1"
  local manifest_file="$backup_dir/manifest.json"

  if [[ ! -f "$manifest_file" ]]; then
    log "ERROR: Manifest not found: $manifest_file"
    exit 1
  fi

  local manifest
  manifest="$(cat "$manifest_file")"

  if ! echo "$manifest" | jq -e . > /dev/null 2>&1; then
    log "ERROR: Manifest is not valid JSON"
    exit 1
  fi

  local errors=0
  local file_count
  file_count="$(echo "$manifest" | jq '.files | length')"

  for ((i=0; i<file_count; i++)); do
    local fname expected actual fpath
    fname="$(echo "$manifest" | jq -r ".files[$i].name")"
    expected="$(echo "$manifest" | jq -r ".files[$i].sha256")"
    fpath="$backup_dir/$fname"

    if [[ ! -f "$fpath" ]]; then
      log "ERROR: Missing file: $fname"
      errors=$((errors + 1))
      continue
    fi

    actual="$(compute_checksum "$fpath")"
    if [[ "$expected" != "$actual" ]]; then
      log "ERROR: Checksum mismatch for $fname (expected: $expected, actual: $actual)"
      errors=$((errors + 1))
    fi
  done

  if [[ $errors -gt 0 ]]; then
    log "ERROR: Manifest verification failed with $errors error(s)"
    exit 1
  fi

  log "Manifest verification passed."
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

trap cleanup_on_error EXIT
