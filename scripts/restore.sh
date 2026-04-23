#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/backup-common.sh"

BACKUP_DIR=""
FORCE=false
DRY_RUN=false
CROSS_CLUSTER=false
TEST_MODE=false
CREATE_BACKUP=false

usage() {
  echo "Usage: $(basename "$0") [OPTIONS] <backup-directory>"
  echo ""
  echo "Arguments:"
  echo "  backup-directory   Path to backup directory (e.g., backups/20240115_120000)"
  echo ""
  echo "Options:"
  echo "  --force           Skip all prompts"
  echo "  --dry-run         Show what would be done without executing"
  echo "  --cross-cluster   Enable cross-cluster restore (skips config overwrite)"
  echo "  --createBackup    Create a fresh backup before restoring"
  echo "  --test            Verify backup integrity without restoring"
  echo "  -h, --help        Show this help message"
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        FORCE=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --cross-cluster)
        CROSS_CLUSTER=true
        shift
        ;;
      --createBackup)
        CREATE_BACKUP=true
        shift
        ;;
      --test)
        TEST_MODE=true
        shift
        ;;
      -h|--help)
        usage
        ;;
      -*)
        echo "Unknown option: $1"
        usage
        ;;
      *)
        if [[ -z "$BACKUP_DIR" ]]; then
          BACKUP_DIR="$1"
        else
          echo "Unexpected argument: $1"
          usage
        fi
        shift
        ;;
    esac
  done
}

wait_for_service() {
  local service="$1"
  local cmd
  cmd="$(docker_compose_cmd)"
  local retries=60
  local delay=5

  log "Waiting for $service to be healthy..."
  for ((i=1; i<=retries; i++)); do
    local status
    status="$($cmd ps "$service" --format json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list) and len(data) > 0:
        item = data[0]
    elif isinstance(data, dict):
        item = data
    else:
        item = {}
    print(item.get("Health", item.get("State", "unknown")))
except:
    print("unknown")
' 2>/dev/null || echo "unknown")"
    if [[ "$status" == "healthy" ]]; then
      log "$service is healthy."
      return 0
    fi
    sleep "$delay"
  done

  log "ERROR: $service did not become healthy within $((retries * delay)) seconds"
  return 1
}

main() {
  parse_args "$@"

  if [[ -z "$BACKUP_DIR" ]]; then
    echo "ERROR: Backup directory is required."
    usage
  fi

  # Resolve relative path
  if [[ ! "$BACKUP_DIR" = /* ]]; then
    BACKUP_DIR="$PROJECT_DIR/$BACKUP_DIR"
  fi

  if [[ ! -d "$BACKUP_DIR" ]]; then
    log "ERROR: Backup directory not found: $BACKUP_DIR"
    exit 1
  fi

  load_env
  local stage
  stage="$(get_stage)"
  local cmd
  cmd="$(docker_compose_cmd)"

  LOG_FILE="$BACKUP_DIR/restore.log"
  mkdir -p "$BACKUP_BASE_DIR"
  acquire_lock

  log "Starting restore from: $BACKUP_DIR"
  log "Stage: $stage"

  # Step 1: Pre-flight checks
  log "Running pre-flight checks..."

  if [[ ! -f "$BACKUP_DIR/manifest.json" ]]; then
    log "ERROR: Manifest not found in backup directory"
    exit 1
  fi

  if [[ "$TEST_MODE" == true ]]; then
    log "=== TEST MODE: Verifying backup integrity ==="
    verify_manifest "$BACKUP_DIR"
    log "=== TEST MODE complete. Backup integrity verified. ==="
    release_lock
    exit 0
  fi

  verify_manifest "$BACKUP_DIR"

  # Load manifest for version/host checks
  local source_host
  local manifest_file="$BACKUP_DIR/manifest.json"
  source_host="$(python3 - "$manifest_file" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
try:
    with open(sys.argv[1]) as f: d = json.load(f)
    print(d.get('source_host', ''))
except Exception: pass
PYEOF
)"
  local manifest_elastic_version
  manifest_elastic_version="$(python3 - "$manifest_file" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
try:
    with open(sys.argv[1]) as f: d = json.load(f)
    print(d.get('versions', {}).get('elasticsearch', ''))
except Exception: pass
PYEOF
)"
  local manifest_camunda_version
  manifest_camunda_version="$(python3 - "$manifest_file" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
try:
    with open(sys.argv[1]) as f: d = json.load(f)
    print(d.get('versions', {}).get('camunda', ''))
except Exception: pass
PYEOF
)"

  # Cross-cluster checks
  if [[ "$CROSS_CLUSTER" == true ]]; then
    log "Cross-cluster restore mode enabled."

    if [[ -n "$manifest_elastic_version" && "$manifest_elastic_version" != "${ELASTIC_VERSION:-}" ]]; then
      log "ERROR: Elasticsearch version mismatch. Backup: $manifest_elastic_version, Current: ${ELASTIC_VERSION:-}"
      exit 1
    fi

    if [[ -n "$manifest_camunda_version" && "$manifest_camunda_version" != "${CAMUNDA_VERSION:-}" ]]; then
      log "ERROR: Camunda version mismatch. Backup: $manifest_camunda_version, Current: ${CAMUNDA_VERSION:-}"
      exit 1
    fi

    if [[ -n "$source_host" && "$source_host" != "${HOST:-}" ]]; then
      log "WARNING: Source host mismatch. Backup from: $source_host, Current: ${HOST:-}"
    fi
  fi

  # Host mismatch warning (also for non-cross-cluster)
  if [[ "$CROSS_CLUSTER" == false && -n "$source_host" && "$source_host" != "${HOST:-}" ]]; then
    log "WARNING: This backup was created on a different host ($source_host)."
    log "WARNING: Config restore may contain incorrect hostnames."
  fi

  # Step 2: Interactive warning
  if [[ "$FORCE" == false && "$DRY_RUN" == false ]]; then
    echo ""
    echo "WARNING: This will OVERWRITE ALL current data in the Camunda stack!"
    echo "Backup: $BACKUP_DIR"
    echo ""
    read -r -p "Are you sure you want to continue? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      log "Restore aborted by user."
      release_lock
      exit 0
    fi
  elif [[ "$DRY_RUN" == true ]]; then
    log "=== DRY RUN MODE: Showing what would be done ==="
  fi

  # Step 2b: Pre-restore backup
  if [[ "$CREATE_BACKUP" == true && "$DRY_RUN" == false && "$TEST_MODE" == false ]]; then
    release_lock
    log "Creating pre-restore backup of current state..."
    local pre_restore_log
    pre_restore_log="$BACKUP_BASE_DIR/pre-restore-backup.log"
    if bash "$SCRIPT_DIR/backup.sh" > "$pre_restore_log" 2>&1; then
      log "Pre-restore backup completed. Log: $pre_restore_log"
    else
      log "WARNING: Pre-restore backup failed, continuing with restore. Log: $pre_restore_log"
    fi
    acquire_lock
  fi

  # Step 2c: Collect pre-restore Elasticsearch state for later comparison
  local state_before="$BACKUP_DIR/restore-state-before.json"
  local state_after="$BACKUP_DIR/restore-state-after.json"
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would collect Elasticsearch state (before)"
  else
    collect_es_state "before" "$state_before" || true
  fi

  # Step 3: Stop stack
  log "Stopping Camunda stack..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would run: $cmd down"
  else
    $cmd down
  fi

  # Step 4: Remove volumes (except keycloak-theme)
  log "Removing data volumes..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would remove volumes: orchestration, elastic, postgres, postgres-web"
    log "[DRY-RUN] Would keep volume: keycloak-theme"
  else
    local proj
    proj="$(get_compose_project_name)"
    docker volume rm "${proj}_orchestration" "${proj}_elastic" "${proj}_postgres" "${proj}_postgres-web" 2>/dev/null || true
    log "Volumes removed."
  fi

  # Step 5: Start only the services needed for data restore.
  # Starting the full stack here allows Camunda apps to recreate indices
  # before the Elasticsearch snapshot restore runs.
  log "Starting core services with fresh volumes..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would run: $cmd up -d postgres web-modeler-db elasticsearch"
  else
    $cmd up -d postgres web-modeler-db elasticsearch
  fi

  # Step 6: Wait for Postgres and Elasticsearch
  if [[ "$DRY_RUN" == false ]]; then
    wait_for_service "postgres" || exit 1
    wait_for_service "web-modeler-db" || exit 1
    wait_for_service "elasticsearch" || exit 1
    log "Core services are healthy."
  else
    log "[DRY-RUN] Would wait for postgres, web-modeler-db, elasticsearch to be healthy"
  fi

  # Step 7: Restore Postgres databases
  log "Restoring Keycloak database..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would restore Keycloak DB from: $BACKUP_DIR/keycloak.sql.gz"
  else
    if [[ -f "$BACKUP_DIR/keycloak.sql.gz" ]]; then
      gunzip -c "$BACKUP_DIR/keycloak.sql.gz" | docker exec -i postgres pg_restore \
        -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --clean --if-exists 2>/dev/null || {
        log "WARNING: pg_restore exited with non-zero status (may be normal for existing objects)"
      }
      log "Keycloak database restored."
    else
      log "WARNING: Keycloak backup not found, skipping."
    fi
  fi

  log "Restoring Web Modeler database..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would restore Web Modeler DB from: $BACKUP_DIR/webmodeler.sql.gz"
  else
    if [[ -f "$BACKUP_DIR/webmodeler.sql.gz" ]]; then
      gunzip -c "$BACKUP_DIR/webmodeler.sql.gz" | docker exec -i web-modeler-db pg_restore \
        -U "${WEBMODELER_DB_USER}" -d "${WEBMODELER_DB_NAME}" --clean --if-exists 2>/dev/null || {
        log "WARNING: pg_restore exited with non-zero status (may be normal for existing objects)"
      }
      log "Web Modeler database restored."
    else
      log "WARNING: Web Modeler backup not found, skipping."
    fi
  fi

  # Only core services are running at this point, so no Camunda apps can
  # recreate Elasticsearch indices before the snapshot restore.
  log "Camunda application services remain stopped until restore is complete."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would keep orchestration, identity, optimize, console, keycloak, and web-modeler app services stopped"
  fi

  # Step 8: Restore Elasticsearch
  log "Restoring Elasticsearch snapshot..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would restore Elasticsearch snapshot"
  else
    local snapshot_name
    local snapshot_info_file="$BACKUP_DIR/snapshot-info.json"
    snapshot_name="$(python3 - "$snapshot_info_file" <<'PYEOF' 2>/dev/null || echo ""
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('snapshot', {}).get('name', ''))
except Exception:
    pass
PYEOF
)"

    if [[ -z "$snapshot_name" ]]; then
      # Fallback: try to determine from backup dir timestamp
      local timestamp
      timestamp="$(basename "$BACKUP_DIR")"
      snapshot_name="snapshot_$timestamp"
    fi

    # Copy snapshot data from host backup into the Docker volume before restoring
    local es_backup_dir="$BACKUP_DIR/elasticsearch"
    if [[ -d "$es_backup_dir" ]]; then
      log "Copying snapshot data into Docker volume 'elastic-backup'..."
      docker run --rm \
        -v "$es_backup_dir:/source:ro" \
        -v "elastic-backup:/dest" \
        alpine sh -c 'rm -rf /dest/* && cp -r /source/. /dest/' > /dev/null 2>&1 || {
          log "WARNING: Could not copy snapshot data to volume"
        }
      log "Snapshot data copied to volume 'elastic-backup'."
    else
      log "WARNING: Elasticsearch backup directory not found at $es_backup_dir, skipping snapshot copy."
    fi

    sleep 2

    # Register snapshot repo
    local es_repo_body
    es_repo_body='{"type":"fs","settings":{"location":"/usr/share/elasticsearch/backup","compress":true}}'
    local repo_response
    repo_response="$(curl -s -X PUT "http://localhost:9200/_snapshot/backup-repo" \
      -H 'Content-Type: application/json' \
      -d "$es_repo_body" 2>/dev/null || true)"
    if ! python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('acknowledged') else 1)" "$repo_response" > /dev/null 2>&1; then
      log "WARNING: Could not register snapshot repo: $repo_response"
    fi

    # Verify the snapshot exists BEFORE deleting any indices, so a wrong or
    # incomplete backup directory cannot wipe the live cluster.
    local snapshot_check_code
    snapshot_check_code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:9200/_snapshot/backup-repo/${snapshot_name}" 2>/dev/null || echo "000")"
    if [[ "$snapshot_check_code" != "200" ]]; then
      log "ERROR: Snapshot '$snapshot_name' not found in repository (HTTP $snapshot_check_code). Aborting before deleting any indices."
      exit 1
    fi
    log "Snapshot '$snapshot_name' verified in repository."

    # Delete only Camunda-related indices and data streams, matching the
    # scope of what the snapshot restore will recreate. Using explicit per-item
    # deletes avoids needing to relax action.destructive_requires_name.
    log "Clearing Camunda-related Elasticsearch indices..."
    local camunda_regex='^(operate|tasklist|optimize|zeebe|camunda-|\.camunda|\.tasks)'
    local idx
    while IFS= read -r idx; do
      [[ -z "$idx" ]] && continue
      curl -s -X DELETE "http://localhost:9200/${idx}" > /dev/null || true
    done < <(curl -s "http://localhost:9200/_cat/indices?h=index&expand_wildcards=all" 2>/dev/null | grep -E "$camunda_regex" || true)

    log "Clearing Camunda-related Elasticsearch data streams..."
    local ds_tmp
    ds_tmp="$(mktemp)"
    curl -s "http://localhost:9200/_data_stream?expand_wildcards=all" > "$ds_tmp" 2>/dev/null || true
    local data_streams
    data_streams="$(python3 - "$ds_tmp" <<'PYEOF' 2>/dev/null || true
import json, re, sys
pattern = re.compile(r'^(operate|tasklist|optimize|zeebe|camunda-|\.camunda|\.tasks)')
try:
    with open(sys.argv[1]) as f: d = json.load(f)
    for ds in d.get('data_streams', []):
        name = ds.get('name', '')
        if pattern.match(name):
            print(name)
except Exception:
    pass
PYEOF
)"
    rm -f "$ds_tmp"
    if [[ -n "$data_streams" ]]; then
      while IFS= read -r ds; do
        [[ -z "$ds" ]] && continue
        curl -s -X DELETE "http://localhost:9200/_data_stream/${ds}" > /dev/null || true
      done <<< "$data_streams"
    fi
    sleep 2

    # Restore snapshot
    log "Restoring snapshot: $snapshot_name"
    local restore_response
    local restore_body='{"indices":"*,-.logs-*,-.ds-.logs-*,-ilm-history-*,-.ds-ilm-history-*","ignore_unavailable":true,"include_global_state":true}'
    restore_response="$(curl -s -X POST "http://localhost:9200/_snapshot/backup-repo/${snapshot_name}/_restore?wait_for_completion=true" \
      -H 'Content-Type: application/json' \
      -d "$restore_body" 2>/dev/null || true)"

    local restore_status
    restore_status="$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    if 'error' in d:
        reason = d['error'].get('reason', str(d['error']))
        print('ERROR:' + reason)
    elif 'snapshot' in d:
        print(d['snapshot'].get('state', 'UNKNOWN'))
    else:
        print('UNKNOWN')
except Exception as e:
    print('UNKNOWN')
" "$restore_response" 2>/dev/null || echo "UNKNOWN")"

    if [[ "$restore_status" == "SUCCESS" ]]; then
      log "Elasticsearch snapshot restored successfully."
    elif [[ "$restore_status" == ERROR* ]]; then
      log "WARNING: Elasticsearch restore failed: $restore_status"
    else
      log "WARNING: Elasticsearch restore state: $restore_status"
    fi
  fi

  # Step 9: Restore Zeebe state
  log "Restoring Zeebe state..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would run: $cmd create orchestration"
    log "[DRY-RUN] Would restore Zeebe state from: $BACKUP_DIR/orchestration.tar.gz"
  else
    if [[ -f "$BACKUP_DIR/orchestration.tar.gz" ]]; then
      local zeebe_vol
      zeebe_vol="$(compose_volume_name orchestration)"
      $cmd create orchestration > /dev/null 2>&1 || true
      docker run --rm \
        -v "${zeebe_vol}:/data" \
        -v "$BACKUP_DIR:/backup" \
        alpine sh -c "cd /data && tar xzf /backup/orchestration.tar.gz"
      log "Zeebe state restored."
    else
      log "WARNING: Orchestration backup not found, skipping."
    fi
  fi

  # Step 10: Restore configs
  if [[ "$CROSS_CLUSTER" == true ]]; then
    log "Cross-cluster mode: configs will NOT be overwritten."
    log "Extracting configs to restored-configs/ for reference..."
    if [[ "$DRY_RUN" == false && -f "$BACKUP_DIR/configs.tar.gz" ]]; then
      mkdir -p "$BACKUP_DIR/restored-configs"
      tar xzf "$BACKUP_DIR/configs.tar.gz" -C "$BACKUP_DIR/restored-configs"
      log "Configs extracted to: $BACKUP_DIR/restored-configs"
    fi
  else
    log "Restoring configuration files..."
    if [[ "$DRY_RUN" == true ]]; then
      log "[DRY-RUN] Would extract configs.tar.gz to project root"
    else
      if [[ -f "$BACKUP_DIR/configs.tar.gz" ]]; then
        tar xzf "$BACKUP_DIR/configs.tar.gz" -C "$PROJECT_DIR"
        log "Configuration files restored."
      else
        log "WARNING: Config backup not found, skipping."
      fi
    fi
  fi

  # Step 11: Restart stack
  log "Restarting stack..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would run: $cmd up -d"
  else
    $cmd up -d
    sleep 5
  fi

  # Step 12: Health check
  log "Waiting for all services to be healthy..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would check service health"
    log "=== DRY RUN complete ==="
  else
    sleep 10
    check_services_health || {
      log "WARNING: Some services are not healthy yet. Check with: docker compose ps"
    }

    # Collect post-restore state and compare to pre-restore state
    collect_es_state "after" "$state_after" || true
    compare_es_state "$state_before" "$state_after" || true

    log "Restore completed successfully."
  fi

  release_lock
}

main "$@"
