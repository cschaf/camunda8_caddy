#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
CREDENTIALS_FILE="$PROJECT_DIR/.env-credentials"
LOG_FILE="${MONITOR_LOG_FILE:-$PROJECT_DIR/monitor.log}"
LOG_MAX_SIZE="${MONITOR_LOG_MAX_SIZE:-10485760}"   # 10 MiB default
LOG_MAX_ARCHIVES="${MONITOR_LOG_MAX_ARCHIVES:-5}"
BACKUP_LOCK_DIR="$PROJECT_DIR/backups/.backup.lock"
BACKUP_LOCK_FILE="$BACKUP_LOCK_DIR/pid"

rotate_log_if_needed() {
  [[ -z "$LOG_FILE" ]] && return 0
  [[ ! -f "$LOG_FILE" ]] && return 0

  local size
  size="$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)"
  [[ "$size" -le "$LOG_MAX_SIZE" ]] && return 0

  # Rotate existing archives up
  local i
  for ((i = LOG_MAX_ARCHIVES - 1; i >= 1; i--)); do
    local src="$LOG_FILE.$i"
    local dst="$LOG_FILE.$((i + 1))"
    [[ -f "$src" ]] && mv -f "$src" "$dst"
  done

  mv -f "$LOG_FILE" "$LOG_FILE.1"
}

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$msg" >> "$LOG_FILE"
  fi
}

# Check if a backup or restore is currently running.
# Both scripts use the same lock directory via backup-common.sh.
is_backup_or_restore_running() {
  if [[ ! -f "$BACKUP_LOCK_FILE" ]]; then
    return 1
  fi

  local pid
  pid="$(cat "$BACKUP_LOCK_FILE" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then
    return 1
  fi

  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  return 1
}

# Load environment from .env (and .env-credentials, for consistency — the
# keys used by this script live in .env, but the order is preserved so any
# future overlap with .env-credentials is predictable).
load_env() {
  if [[ ! -f "$ENV_FILE" && ! -f "$CREDENTIALS_FILE" ]]; then
    log "ERROR: .env file not found. Run: cp .env.example .env"
    exit 1
  fi

  set -a
  # shellcheck source=/dev/null
  # Remove UTF-8 BOM if present (common on Windows)
  for source_file in "$ENV_FILE" "$CREDENTIALS_FILE"; do
    [[ -f "$source_file" ]] || continue
    source <(sed '1s/^\xEF\xBB\xBF//' "$source_file")
  done
  set +a
}

# Determine the current stage
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

main() {
  rotate_log_if_needed

  # Skip entirely if a backup or restore is in progress.
  if is_backup_or_restore_running; then
    log "Backup or restore is currently running. Skipping monitor check."
    exit 0
  fi

  load_env

  local stage
  stage="$(get_stage)"

  local compose_cmd=(
    docker compose
    --env-file "$ENV_FILE"
    --env-file "$CREDENTIALS_FILE"
    -f "$PROJECT_DIR/docker-compose.yaml"
    -f "$PROJECT_DIR/stages/${stage}.yaml"
  )

  # Get the list of expected services from compose config.
  # Exclude camunda-data-init because it is a one-shot init container
  # that exits after completing its work and is not expected to keep running.
  local expected_services=()
  local config_services
  if ! config_services="$("${compose_cmd[@]}" config --services 2>&1)"; then
    log "ERROR: Could not determine expected services from docker compose config"
    while IFS= read -r line; do
      [[ -n "$line" ]] && log "  $line"
    done <<< "$config_services"
    exit 1
  fi

  local service
  while IFS= read -r service; do
    [[ -z "$service" || "$service" == "camunda-data-init" ]] && continue
    expected_services+=("$service")
  done <<< "$config_services"

  if [[ ${#expected_services[@]} -eq 0 ]]; then
    log "ERROR: Could not determine expected services from docker compose config"
    exit 1
  fi

  # Check running containers and their health.
  local issues=()
  local container_status
  if ! container_status="$("${compose_cmd[@]}" ps --format '{{.Service}}	{{.State}}	{{.Health}}	{{.Name}}' 2>&1)"; then
    log "ERROR: Could not query docker compose container status"
    while IFS= read -r line; do
      [[ -n "$line" ]] && log "  $line"
    done <<< "$container_status"
    exit 1
  fi

  for service in "${expected_services[@]}"; do
    local state="" health="" name=""

    while IFS=$'\t' read -r status_service status_state status_health status_name; do
      if [[ "$status_service" == "$service" ]]; then
        state="$status_state"
        health="$status_health"
        name="$status_name"
        break
      fi
    done <<< "$container_status"

    if [[ -z "$state" ]]; then
      issues+=("$service: missing (not running)")
      continue
    fi

    if [[ "$state" != "running" ]]; then
      issues+=("$service: state is '$state' (expected 'running')")
      continue
    fi

    # Health is empty for containers without a healthcheck, which is fine.
    # Only flag when explicitly "unhealthy".
    if [[ "$health" == "unhealthy" ]]; then
      issues+=("$service: health is '$health'")
    fi
  done

  if [[ ${#issues[@]} -eq 0 ]]; then
    log "All ${#expected_services[@]} expected services are running and healthy."
    exit 0
  fi

  log "Cluster health check failed for STAGE=$stage:"
  for issue in "${issues[@]}"; do
    log "  - $issue"
  done

  log "Attempting to recover by running scripts/start.sh..."
  if ! bash "$PROJECT_DIR/scripts/start.sh" 2>&1 | tee -a "$LOG_FILE"; then
    log "ERROR: scripts/start.sh failed"
    exit 1
  fi

  log "Recovery completed."
}

main "$@"
