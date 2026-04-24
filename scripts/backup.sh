#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Pre-parse --env-file so backup-common.sh can honor it
for ((i=1; i<=$#; i++)); do
  if [[ "${!i}" == "--env-file" ]]; then
    next=$((i+1))
    if [[ $next -le $# ]]; then
      ENV_FILE="${!next}"
      export ENV_FILE
      set -- "${@:1:i-1}" "${@:i+2}"
      break
    fi
  fi
done

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/backup-common.sh"

APP_SERVICES_STOPPED=false
BACKUP_COMPOSE_CMD=""
BACKUP_APP_SERVICES=(
  orchestration
  connectors
  optimize
  identity
  keycloak
  web-modeler-restapi
  web-modeler-webapp
  web-modeler-websockets
  console
)
TEST_MODE=false
RETENTION_DAYS=7
CUSTOM_BACKUP_DIR=""
ENCRYPT_TO=""
BACKUP_DIR_IN_PROGRESS=""
BACKUP_FAILED_MARKED=false

mark_failed_backup_dir() {
  if [[ -z "${BACKUP_DIR_IN_PROGRESS:-}" || "$TEST_MODE" == true || "$BACKUP_FAILED_MARKED" == true ]]; then
    return 0
  fi
  if [[ ! -d "$BACKUP_DIR_IN_PROGRESS" || "$BACKUP_DIR_IN_PROGRESS" == *_FAILED* ]]; then
    return 0
  fi

  local failed_dir="${BACKUP_DIR_IN_PROGRESS}_FAILED"
  local suffix=1
  while [[ -e "$failed_dir" ]]; do
    failed_dir="${BACKUP_DIR_IN_PROGRESS}_FAILED_${suffix}"
    suffix=$((suffix + 1))
  done

  log "Marking incomplete backup directory as failed: $failed_dir"
  if mv -- "$BACKUP_DIR_IN_PROGRESS" "$failed_dir"; then
    BACKUP_DIR_IN_PROGRESS="$failed_dir"
    LOG_FILE="$failed_dir/backup.log"
    BACKUP_FAILED_MARKED=true
    log "Incomplete backup moved to: $failed_dir"
  else
    log "WARNING: Could not mark incomplete backup directory as failed: $BACKUP_DIR_IN_PROGRESS"
  fi
}

usage() {
  echo "Usage: $(basename "$0") [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --simulate          Simulate backup without modifying data (alias: --test)"
  echo "  --retention-days N  Delete backups older than N days (default: 7)"
  echo "  --backup-dir DIR    Base directory for backups (default: backups/)"
  echo "  --encrypt-to ID     Also write encrypted backup archive for a gpg or age recipient"
  echo "  --env-file FILE     Use a custom env file instead of .env"
  echo "  -h, --help          Show this help message"
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --simulate)
        TEST_MODE=true
        shift
        ;;
      --test)
        TEST_MODE=true
        shift
        ;;
      --retention-days)
        RETENTION_DAYS="$2"
        shift 2
        ;;
      --backup-dir)
        CUSTOM_BACKUP_DIR="$2"
        shift 2
        ;;
      --encrypt-to)
        ENCRYPT_TO="$2"
        shift 2
        ;;
      --env-file)
        shift 2
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

create_encrypted_backup_archive() {
  local backup_dir="$1"
  local backup_base_dir="$2"
  local recipient="$3"
  local encrypted_base_dir
  encrypted_base_dir="$(dirname "$backup_base_dir")/backups-encrypted"
  local backup_name
  backup_name="$(basename "$backup_dir")"
  local tmp_tar="$encrypted_base_dir/${backup_name}.tar.gz.tmp"

  mkdir -p "$encrypted_base_dir"

  if command -v gpg >/dev/null 2>&1; then
    local artifact="$encrypted_base_dir/${backup_name}.tar.gz.gpg"
    log "Creating encrypted backup archive with gpg: $artifact"
    tar czf "$tmp_tar" -C "$backup_base_dir" "$backup_name"
    if gpg --batch --yes --encrypt --recipient "$recipient" --output "$artifact" "$tmp_tar" >>"$LOG_FILE" 2>&1; then
      rm -f "$tmp_tar"
      log "Encrypted backup archive created: $artifact"
      return 0
    fi
    rm -f "$tmp_tar"
    log "ERROR: gpg encryption failed"
    return 1
  fi

  if command -v age >/dev/null 2>&1; then
    local artifact="$encrypted_base_dir/${backup_name}.tar.gz.age"
    log "Creating encrypted backup archive with age: $artifact"
    tar czf "$tmp_tar" -C "$backup_base_dir" "$backup_name"
    if age -r "$recipient" -o "$artifact" "$tmp_tar" >>"$LOG_FILE" 2>&1; then
      rm -f "$tmp_tar"
      log "Encrypted backup archive created: $artifact"
      return 0
    fi
    rm -f "$tmp_tar"
    log "ERROR: age encryption failed"
    return 1
  fi

  log "ERROR: --encrypt-to requires gpg or age in PATH"
  return 1
}

backup_cleanup_on_error() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    log "ERROR: Backup script failed with exit code $exit_code"
    mark_failed_backup_dir || true
    if [[ "$APP_SERVICES_STOPPED" == true && -n "$BACKUP_COMPOSE_CMD" ]]; then
      log "Attempting to restart application services after failure..."
      $BACKUP_COMPOSE_CMD start "${BACKUP_APP_SERVICES[@]}" >>"$LOG_FILE" 2>&1 || true
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
  local backup_stop_timeout
  backup_stop_timeout="${BACKUP_STOP_TIMEOUT:-180}"
  if [[ ! "$backup_stop_timeout" =~ ^[0-9]+$ || "$backup_stop_timeout" -le 0 ]]; then
    log "ERROR: BACKUP_STOP_TIMEOUT must be a positive integer (got: $backup_stop_timeout)"
    exit 1
  fi

  local backup_base_dir="$BACKUP_BASE_DIR"
  if [[ -n "$CUSTOM_BACKUP_DIR" ]]; then
    backup_base_dir="$CUSTOM_BACKUP_DIR"
    mkdir -p "$backup_base_dir"
  fi

  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local backup_dir="$backup_base_dir/$timestamp"

  if [[ "$TEST_MODE" == true ]]; then
    backup_dir="$backup_base_dir/TEST_${timestamp}"
  fi

  mkdir -p "$backup_dir"
  LOG_FILE="$backup_dir/backup.log"
  BACKUP_DIR_IN_PROGRESS="$backup_dir"

  acquire_lock

  log "Starting backup to $backup_dir"
  log "Stage: $stage"
  log "Application service stop timeout: ${backup_stop_timeout}s"

  # Step 3: Check stack status
  log "Checking stack status..."
  local running_count
  running_count="$($cmd ps --filter status=running --format '{{.Name}}' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$running_count" -eq 0 ]]; then
    log "ERROR: Stack is not running (0 containers running). Start it first with scripts/start.sh"
    exit 1
  fi
  log "Stack has $running_count running container(s)."

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
      log "ERROR: No config files found to back up"
      exit 1
    else
      if tar czf "$config_archive" -C "$PROJECT_DIR" "${config_files[@]}" 2>/dev/null; then
        log "Configs backed up: $config_archive (${#config_files[@]} files)"
      else
        log "ERROR: Config archive failed"
        exit 1
      fi
    fi
  fi

  # Step 5-9: Orchestration stop + all backups while stopped + restart
  log "Stopping application services for cold backup..."
  if [[ "$TEST_MODE" == true ]]; then
    log "[TEST] Would collect Elasticsearch state to: $backup_dir/backup-state.json"
    log "[TEST] Would stop application services with timeout ${backup_stop_timeout}s: ${BACKUP_APP_SERVICES[*]}"
    log "[TEST] Would backup Zeebe state from volume 'orchestration'"
    log "[TEST] Would pg_dump Keycloak DB: ${POSTGRES_DB:-}"
    log "[TEST] Would pg_dump Web Modeler DB: ${WEBMODELER_DB_NAME:-}"
    log "[TEST] Would create Elasticsearch snapshot"
  else
    collect_es_state "backup" "$backup_dir/backup-state.json" || true

    log "Stopping application services for consistent cold backup (timeout: ${backup_stop_timeout}s)..."
    $cmd stop --timeout "$backup_stop_timeout" "${BACKUP_APP_SERVICES[@]}"
    APP_SERVICES_STOPPED=true
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
    if ! docker exec postgres pg_dump -Fc -U "${POSTGRES_USER}" "${POSTGRES_DB}" 2>>"$LOG_FILE" | gzip > "$backup_dir/keycloak.sql.gz"; then
      log "ERROR: Keycloak DB backup failed"
      exit 1
    fi
    if ! gunzip -t "$backup_dir/keycloak.sql.gz" 2>>"$LOG_FILE"; then
      log "ERROR: Keycloak DB backup produced invalid gzip"
      exit 1
    fi
    log "Keycloak DB backed up: $backup_dir/keycloak.sql.gz"

    log "Backing up Web Modeler database..."
    if ! docker exec web-modeler-db pg_dump -Fc -U "${WEBMODELER_DB_USER}" "${WEBMODELER_DB_NAME}" 2>>"$LOG_FILE" | gzip > "$backup_dir/webmodeler.sql.gz"; then
      log "ERROR: Web Modeler DB backup failed"
      exit 1
    fi
    if ! gunzip -t "$backup_dir/webmodeler.sql.gz" 2>>"$LOG_FILE"; then
      log "ERROR: Web Modeler DB backup produced invalid gzip"
      exit 1
    fi
    log "Web Modeler DB backed up: $backup_dir/webmodeler.sql.gz"

    log "Creating Elasticsearch snapshot..."
    # Ensure the Docker volume has open permissions for the elasticsearch user
    docker run --rm -v "elastic-backup:/backup" alpine sh -c "chmod -R 777 /backup 2>/dev/null || true" > /dev/null 2>&1 || true

    # Register snapshot repository
    local es_repo_body
    es_repo_body='{"type":"fs","settings":{"location":"/usr/share/elasticsearch/backup","compress":true}}'
    curl -fsS -X PUT "http://localhost:9200/_snapshot/backup-repo" \
      -H 'Content-Type: application/json' \
      -d "$es_repo_body" > /dev/null || {
        log "ERROR: Could not register snapshot repo"
        exit 1
      }

    # Create snapshot
    local snapshot_name="snapshot_$timestamp"
    local snapshot_info_file="$backup_dir/snapshot-info.json"
    local es_success=false
    local snapshot_body='{"indices":"*,-.logs-*,-.ds-.logs-*,-ilm-history-*,-.ds-ilm-history-*","ignore_unavailable":true,"include_global_state":true,"feature_states":["none"]}'
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
      log "ERROR: Elasticsearch snapshot failed: $snapshot_state"
      exit 1
    else
      log "ERROR: Elasticsearch snapshot state: $snapshot_state"
      exit 1
    fi

    # Copy snapshot data from the Docker volume to the host backup directory
    log "Copying snapshot data from Docker volume to backup directory..."
    local es_backup_dir="$backup_dir/elasticsearch"
    mkdir -p "$es_backup_dir"
    docker run --rm \
      -v "elastic-backup:/source:ro" \
      -v "$es_backup_dir:/dest" \
      alpine sh -c 'cp -r /source/. /dest/' > /dev/null 2>&1 || {
        log "ERROR: Could not copy snapshot data from volume"
        exit 1
      }
    log "Snapshot data copied to: $es_backup_dir"

  fi

  # Step 11: Create manifest
  log "Creating manifest..."
  if [[ "$TEST_MODE" == true ]]; then
    log "[TEST] Would create manifest.json"
    log "[TEST] Would start application services: ${BACKUP_APP_SERVICES[*]}"
  else
    create_manifest "$backup_dir"
    if [[ -n "$ENCRYPT_TO" ]]; then
      create_encrypted_backup_archive "$backup_dir" "$backup_base_dir" "$ENCRYPT_TO"
    fi
    BACKUP_DIR_IN_PROGRESS=""

    log "Starting application services..."
    $cmd start "${BACKUP_APP_SERVICES[@]}"
    APP_SERVICES_STOPPED=false
    sleep 2
  fi

  # Step 12: Cleanup old backups
  log "Cleaning up old backups..."
  if [[ "$TEST_MODE" == true ]]; then
    log "[TEST] Would delete backups older than $RETENTION_DAYS days from $backup_base_dir"
  else
    cleanup_old_backups "$RETENTION_DAYS" "$backup_base_dir"
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
