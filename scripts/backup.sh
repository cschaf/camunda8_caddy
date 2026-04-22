#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/backup-common.sh"

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

main() {
  parse_args "$@"

  load_env
  local stage
  stage="$(get_stage)"
  local cmd
  cmd="$(docker_compose_cmd)"

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
    tar czf "$config_archive" \
      -C "$PROJECT_DIR" \
      .env connector-secrets.txt Caddyfile \
      .orchestration/application.yaml \
      .connectors/application.yaml \
      .optimize/environment-config.yaml \
      .identity/application.yaml \
      .console/application.yaml 2>/dev/null || true
    log "Configs backed up: $config_archive"
  fi

  # Step 5-7: Orchestration stop + Zeebe state backup + start
  log "Stopping orchestration for cold backup..."
  if [[ "$TEST_MODE" == true ]]; then
    log "[TEST] Would stop orchestration"
    log "[TEST] Would backup Zeebe state from volume 'orchestration'"
    log "[TEST] Would start orchestration"
  else
    $cmd stop --timeout 60 orchestration || true
    sleep 2

    log "Backing up Zeebe state (volume: orchestration)..."
    local zeebe_retry=0
    local zeebe_max_retries=3
    while true; do
      if docker run --rm \
        -v orchestration:/data \
        -v "$backup_dir:/backup" \
        alpine tar czf /backup/orchestration.tar.gz -C /data . 2>/dev/null; then
        log "Zeebe state backed up."
        break
      fi
      zeebe_retry=$((zeebe_retry + 1))
      if [[ $zeebe_retry -eq $zeebe_max_retries ]]; then
        log "ERROR: Zeebe state backup failed after $zeebe_max_retries attempts"
        break
      fi
      log "WARNING: Zeebe backup failed, retrying in 5s... (attempt $zeebe_retry/$zeebe_max_retries)"
      sleep 5
    done

    log "Starting orchestration..."
    $cmd start orchestration
    sleep 2
  fi

  # Step 8: Keycloak DB backup
  log "Backing up Keycloak database..."
  if [[ "$TEST_MODE" == true ]]; then
    log "[TEST] Would pg_dump Keycloak DB: ${POSTGRES_DB:-}"
  else
    docker exec postgres pg_dump -Fc -U "${POSTGRES_USER}" "${POSTGRES_DB}" | gzip > "$backup_dir/keycloak.sql.gz"
    log "Keycloak DB backed up: $backup_dir/keycloak.sql.gz"
  fi

  # Step 9: Web Modeler DB backup
  log "Backing up Web Modeler database..."
  if [[ "$TEST_MODE" == true ]]; then
    log "[TEST] Would pg_dump Web Modeler DB: ${WEBMODELER_DB_NAME:-}"
  else
    docker exec web-modeler-db pg_dump -Fc -U "${WEBMODELER_DB_USER}" "${WEBMODELER_DB_NAME}" | gzip > "$backup_dir/webmodeler.sql.gz"
    log "Web Modeler DB backed up: $backup_dir/webmodeler.sql.gz"
  fi

  # Step 10: Elasticsearch snapshot
  log "Creating Elasticsearch snapshot..."
  if [[ "$TEST_MODE" == true ]]; then
    log "[TEST] Would register snapshot repo 'backup-repo'"
    log "[TEST] Would create snapshot 'snapshot_$timestamp'"
  else
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
    if curl -s -X PUT "http://localhost:9200/_snapshot/backup-repo/${snapshot_name}?wait_for_completion=true" \
      -H 'Content-Type: application/json' \
      -d '{"indices":"*","ignore_unavailable":true,"include_global_state":true}' > "$snapshot_info_file"; then

      local snapshot_state
      snapshot_state="$(jq -r '.snapshot.state' "$snapshot_info_file" 2>/dev/null || echo "UNKNOWN")"

      if [[ "$snapshot_state" == "SUCCESS" ]]; then
        log "Elasticsearch snapshot created successfully: $snapshot_name"
        es_success=true
      else
        log "WARNING: Elasticsearch snapshot state: $snapshot_state"
      fi
    else
      log "WARNING: Elasticsearch snapshot creation failed"
      echo '{"error":"Snapshot creation failed"}' > "$snapshot_info_file"
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
