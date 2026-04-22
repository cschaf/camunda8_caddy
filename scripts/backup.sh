#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/backup-common.sh"

ORCHESTRATION_STOPPED=false
BACKUP_COMPOSE_CMD=""
TEST_MODE=false

usage() {
  echo "Usage: $(basename "$0") [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --test     Simulate backup without modifying data"
  echo "  -h, --help Show this help message"
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --test)
        TEST_MODE=true
        shift
        ;;
      -h|--help)
        usage
        ;;
      *)
        echo "Unknown option: $1"
        usage
        ;;
    esac
  done
}

backup_cleanup_on_error() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    log "ERROR: Backup script failed with exit code $exit_code"
    if [[ "$ORCHESTRATION_STOPPED" == true && -n "$BACKUP_COMPOSE_CMD" ]]; then
      log "Attempting to restart orchestration after failure..."
      $BACKUP_COMPOSE_CMD start orchestration 2>/dev/null || true
    fi
  fi
  release_lock
  exit $exit_code
}
trap backup_cleanup_on_error EXIT

main() {
  parse_args "$@"

  load_env
  local stage
  stage="$(get_stage)"
  local cmd
  cmd="$(docker_compose_cmd)"
  BACKUP_COMPOSE_CMD="$cmd"

  mkdir -p "$BACKUP_BASE_DIR"
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local backup_dir="$BACKUP_BASE_DIR/$timestamp"

  if [[ "$TEST_MODE" == true ]]; then
    backup_dir="$BACKUP_BASE_DIR/TEST_${timestamp}"
  fi

  mkdir -p "$backup_dir"
  LOG_FILE="$backup_dir/backup.log"

  acquire_lock

  log "Starting backup to $backup_dir"
  log "Stage: $stage"

  # Step 3: Check stack status
  log "Checking stack status..."
  if ! $cmd ps &>/dev/null; then
    log "ERROR: Stack is not running. Start it first with scripts/start.sh"
    exit 1
  fi

  check_services_health || true

  # Step 4: Backup configs
  log "Backing up configuration files..."
  local config_archive="$backup_dir/configs.tar.gz"
  if [[ "$TEST_MODE" == true ]]; then
    log "[TEST] Would create config archive: $config_archive"
    log "[TEST] Including: .env, connector-secrets.txt, Caddyfile, .*/application.yaml"
  else
    local config_files=()
    local all_config_paths=(
      ".env"
      "connector-secrets.txt"
      "Caddyfile"
      ".orchestration/application.yaml"
      ".connectors/application.yaml"
      ".optimize/environment-config.yaml"
      ".identity/application.yaml"
      ".console/application.yaml"
    )
    for f in "${all_config_paths[@]}"; do
      [[ -f "$PROJECT_DIR/$f" ]] && config_files+=("$f")
    done

    if [[ ${#config_files[@]} -eq 0 ]]; then
      log "WARNING: No config files found to back up"
    else
      if tar czf "$config_archive" -C "$PROJECT_DIR" "${config_files[@]}" 2>/dev/null; then
        log "Configs backed up: $config_archive (${#config_files[@]} files)"
      else
        log "WARNING: Config archive may be incomplete"
      fi
    fi
  fi

  # Step 5-9: Orchestration stop + all backups while stopped + restart
  log "Stopping orchestration for cold backup..."
  if [[ "$TEST_MODE" == true ]]; then
    log "[TEST] Would stop orchestration"
    log "[TEST] Would backup Zeebe state from volume 'orchestration'"
    log "[TEST] Would pg_dump Keycloak DB: ${POSTGRES_DB:-}"
    log "[TEST] Would pg_dump Web Modeler DB: ${WEBMODELER_DB_NAME:-}"
    log "[TEST] Would create Elasticsearch snapshot"
    log "[TEST] Would start orchestration"
  else
    $cmd stop --timeout 60 orchestration || true
    ORCHESTRATION_STOPPED=true
    sleep 2

    log "Backing up Zeebe state (volume: orchestration)..."
    local zeebe_retry=0
    local zeebe_max_retries=3
    while true; do
      local zeebe_vol
      zeebe_vol="$(compose_volume_name orchestration)"
      if docker run --rm \
        -v "${zeebe_vol}:/data" \
        -v "$backup_dir:/backup" \
        alpine tar czf /backup/orchestration.tar.gz -C /data . 2>/dev/null; then
        log "Zeebe state backed up."
        break
      fi
      zeebe_retry=$((zeebe_retry + 1))
      if [[ $zeebe_retry -eq $zeebe_max_retries ]]; then
        log "ERROR: Zeebe state backup failed after $zeebe_max_retries attempts"
        exit 1
      fi
      log "WARNING: Zeebe backup failed, retrying in 5s... (attempt $zeebe_retry/$zeebe_max_retries)"
      sleep 5
    done

    log "Backing up Keycloak database..."
    if docker exec postgres pg_dump -Fc -U "${POSTGRES_USER}" "${POSTGRES_DB}" | gzip > "$backup_dir/keycloak.sql.gz" 2>/dev/null; then
      log "Keycloak DB backed up: $backup_dir/keycloak.sql.gz"
    else
      log "ERROR: Keycloak DB backup failed"
    fi

    log "Backing up Web Modeler database..."
    if docker exec web-modeler-db pg_dump -Fc -U "${WEBMODELER_DB_USER}" "${WEBMODELER_DB_NAME}" | gzip > "$backup_dir/webmodeler.sql.gz" 2>/dev/null; then
      log "Web Modeler DB backed up: $backup_dir/webmodeler.sql.gz"
    else
      log "ERROR: Web Modeler DB backup failed"
    fi

    log "Creating Elasticsearch snapshot..."
    # Ensure the Docker volume has open permissions for the elasticsearch user
    docker run --rm -v "elastic-backup:/backup" alpine sh -c "chmod -R 777 /backup 2>/dev/null || true" > /dev/null 2>&1 || true

    # Register snapshot repository
    local es_repo_body
    es_repo_body='{"type":"fs","settings":{"location":"/usr/share/elasticsearch/backup","compress":true}}'
    curl -s -X PUT "http://localhost:9200/_snapshot/backup-repo" \
      -H 'Content-Type: application/json' \
      -d "$es_repo_body" > /dev/null || {
        log "WARNING: Could not register snapshot repo"
      }

    # Create snapshot
    local snapshot_name="snapshot_$timestamp"
    local snapshot_info_file="$backup_dir/snapshot-info.json"
    local es_success=false
    local snapshot_body='{"indices":"*,-.logs-*,-.ds-.logs-*,-ilm-history-*,-.ds-ilm-history-*","ignore_unavailable":true,"include_global_state":true}'
    curl -s -X PUT "http://localhost:9200/_snapshot/backup-repo/${snapshot_name}?wait_for_completion=true" \
      -H 'Content-Type: application/json' \
      -d "$snapshot_body" > "$snapshot_info_file" 2>/dev/null || true

    local snapshot_state
    snapshot_state="$(python3 - "$snapshot_info_file" <<'PYEOF' 2>/dev/null || echo "UNKNOWN"
import json, sys

snapshot_info_file = sys.argv[1]
try:
    with open(snapshot_info_file) as f:
        d = json.load(f)
    if 'error' in d:
        reason = d['error'].get('reason', str(d['error']))
        print('ERROR:' + reason)
        sys.exit(1)
    print(d.get('snapshot', {}).get('state', 'UNKNOWN'))
except Exception:
    print('UNKNOWN')
    sys.exit(1)
PYEOF
)"

    if [[ "$snapshot_state" == "SUCCESS" ]]; then
      log "Elasticsearch snapshot created successfully: $snapshot_name"
      es_success=true
    elif [[ "$snapshot_state" == ERROR* ]]; then
      log "WARNING: Elasticsearch snapshot failed: $snapshot_state"
    else
      log "WARNING: Elasticsearch snapshot state: $snapshot_state"
    fi

    # Copy snapshot data from the Docker volume to the host backup directory
    if [[ "$es_success" == true ]]; then
      log "Copying snapshot data from Docker volume to backup directory..."
      local es_backup_dir="$backup_dir/elasticsearch"
      mkdir -p "$es_backup_dir"
      docker run --rm \
        -v "elastic-backup:/source:ro" \
        -v "$es_backup_dir:/dest" \
        alpine sh -c 'cp -r /source/. /dest/' > /dev/null 2>&1 || {
          log "WARNING: Could not copy snapshot data from volume"
        }
      log "Snapshot data copied to: $es_backup_dir"
    fi

    log "Starting orchestration..."
    $cmd start orchestration || true
    ORCHESTRATION_STOPPED=false
    sleep 2
  fi

  # Step 11: Create manifest
  log "Creating manifest..."
  if [[ "$TEST_MODE" == true ]]; then
    log "[TEST] Would create manifest.json"
  else
    create_manifest "$backup_dir"
  fi

  # Step 12: Cleanup old backups
  log "Cleaning up old backups..."
  if [[ "$TEST_MODE" == true ]]; then
    log "[TEST] Would delete backups older than 7 days"
  else
    cleanup_old_backups 7
  fi

  release_lock

  if [[ "$TEST_MODE" == true ]]; then
    log "=== TEST MODE complete. Simulated backup: $backup_dir ==="
    rm -rf "$backup_dir"
  else
    log "Backup completed successfully: $backup_dir"
  fi
}

main "$@"
