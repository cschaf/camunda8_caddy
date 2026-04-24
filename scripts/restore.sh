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
      # Rebuild args without --env-file and its value
      set -- "${@:1:i-1}" "${@:i+2}"
      break
    fi
  fi
done

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/backup-common.sh"

BACKUP_DIR=""
FORCE=false
DRY_RUN=false
CROSS_CLUSTER=false
TEST_MODE=false
CREATE_PRE_BACKUP=true
DEPRECATED_CREATE_BACKUP_USED=false
REHOST_KEYCLOAK=false
RESTORE_COMPONENTS="all"
RESTORE_ALL=false
RESTORE_KEYCLOAK=false
RESTORE_WEBMODELER=false
RESTORE_ELASTICSEARCH=false
RESTORE_ORCHESTRATION=false
RESTORE_CONFIGS=false
STACK_DOWN_FOR_RESTORE=false
RESTORE_COMPOSE_CMD=""
PRE_RESTORE_BACKUP_PATH=""

restore_cleanup_on_error() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    log "ERROR: Restore script failed with exit code $exit_code"
    if [[ "$STACK_DOWN_FOR_RESTORE" == true && -n "$RESTORE_COMPOSE_CMD" ]]; then
      log "Attempting to restart stack after restore failure..."
      $RESTORE_COMPOSE_CMD up -d >>"$LOG_FILE" 2>&1 || true
      if [[ -n "$PRE_RESTORE_BACKUP_PATH" ]]; then
        log "ERROR: Restore failed. Stack may be inconsistent. Pre-restore backup stored at $PRE_RESTORE_BACKUP_PATH; run: scripts/restore.sh --force $PRE_RESTORE_BACKUP_PATH"
      else
        log "ERROR: Restore failed. Stack may be inconsistent. Pre-restore backup unavailable; no rollback backup was created or its path could not be determined."
      fi
    fi
  fi
  release_lock
  exit $exit_code
}
trap restore_cleanup_on_error EXIT

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
  echo "  --no-pre-backup   Do not create a rollback backup before restoring"
  echo "  --create-backup   Deprecated; pre-restore backups are enabled by default"
  echo "  --rehost-keycloak Patch restored Keycloak clients to the current HOST and local client secrets"
  echo "  --components LIST Restore only selected components"
  echo "                    Allowed: all,keycloak,webmodeler,elasticsearch,orchestration,configs"
  echo "                    Example: --components keycloak,webmodeler"
  echo "  --verify          Verify backup integrity without restoring"
  echo "  --env-file FILE   Use a custom env file instead of .env"
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
      --create-backup)
        CREATE_PRE_BACKUP=true
        DEPRECATED_CREATE_BACKUP_USED=true
        shift
        ;;
      --createBackup)
        CREATE_PRE_BACKUP=true
        DEPRECATED_CREATE_BACKUP_USED=true
        shift
        ;;
      --no-pre-backup)
        CREATE_PRE_BACKUP=false
        shift
        ;;
      --rehost-keycloak)
        REHOST_KEYCLOAK=true
        shift
        ;;
      --components)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --components requires a comma-separated list"
          usage
        fi
        RESTORE_COMPONENTS="$2"
        shift 2
        ;;
      --verify)
        TEST_MODE=true
        shift
        ;;
      --test)
        TEST_MODE=true
        shift
        ;;
      --env-file)
        shift 2
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

rehost_keycloak_clients() {
  if [[ -z "${HOST:-}" ]]; then
    log "ERROR: HOST is required for --rehost-keycloak"
    exit 1
  fi

  local sql_file="$SCRIPT_DIR/rehost-keycloak.sql"
  if [[ ! -f "$sql_file" ]]; then
    log "ERROR: Keycloak rehost SQL not found: $sql_file"
    exit 1
  fi

  log "Rehosting Keycloak clients to HOST=$HOST..."
  if ! docker exec -i postgres psql \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DB}" \
    -v "host=${HOST}" \
    -v "connectors_secret=${CONNECTORS_CLIENT_SECRET:-}" \
    -v "console_secret=${CONSOLE_CLIENT_SECRET:-}" \
    -v "orchestration_secret=${ORCHESTRATION_CLIENT_SECRET:-}" \
    -v "optimize_secret=${OPTIMIZE_CLIENT_SECRET:-}" \
    -v "identity_secret=${CAMUNDA_IDENTITY_CLIENT_SECRET:-}" \
    < "$sql_file"; then
    log "ERROR: Keycloak rehost failed"
    exit 1
  fi
  log "Keycloak clients rehosted for HOST=$HOST."
}

configure_restore_components() {
  RESTORE_ALL=false
  RESTORE_KEYCLOAK=false
  RESTORE_WEBMODELER=false
  RESTORE_ELASTICSEARCH=false
  RESTORE_ORCHESTRATION=false
  RESTORE_CONFIGS=false

  local normalized
  normalized="$(echo "$RESTORE_COMPONENTS" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [[ -z "$normalized" || "$normalized" == "all" ]]; then
    RESTORE_ALL=true
    RESTORE_KEYCLOAK=true
    RESTORE_WEBMODELER=true
    RESTORE_ELASTICSEARCH=true
    RESTORE_ORCHESTRATION=true
    RESTORE_CONFIGS=true
    RESTORE_COMPONENTS="all"
    return
  fi

  IFS=',' read -r -a selected <<< "$normalized"
  local component
  for component in "${selected[@]}"; do
    case "$component" in
      keycloak)
        RESTORE_KEYCLOAK=true
        ;;
      webmodeler|web-modeler)
        RESTORE_WEBMODELER=true
        ;;
      elasticsearch|elastic)
        RESTORE_ELASTICSEARCH=true
        ;;
      orchestration|zeebe)
        RESTORE_ORCHESTRATION=true
        ;;
      configs|config|configuration)
        RESTORE_CONFIGS=true
        ;;
      all)
        RESTORE_ALL=true
        RESTORE_KEYCLOAK=true
        RESTORE_WEBMODELER=true
        RESTORE_ELASTICSEARCH=true
        RESTORE_ORCHESTRATION=true
        RESTORE_CONFIGS=true
        RESTORE_COMPONENTS="all"
        return
        ;;
      *)
        echo "ERROR: Unknown restore component: $component"
        usage
        ;;
    esac
  done

  RESTORE_COMPONENTS="$normalized"
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

validate_restore_inputs() {
  local backup_dir="$1"
  local missing=0
  local required_files=("manifest.json")
  [[ "$RESTORE_CONFIGS" == true ]] && required_files+=("configs.tar.gz")
  [[ "$RESTORE_KEYCLOAK" == true ]] && required_files+=("keycloak.sql.gz")
  [[ "$RESTORE_WEBMODELER" == true ]] && required_files+=("webmodeler.sql.gz")
  [[ "$RESTORE_ORCHESTRATION" == true ]] && required_files+=("orchestration.tar.gz")
  [[ "$RESTORE_ELASTICSEARCH" == true ]] && required_files+=("snapshot-info.json")

  log "Validating required restore artifacts..."
  for rel in "${required_files[@]}"; do
    if [[ ! -s "$backup_dir/$rel" ]]; then
      log "ERROR: Required backup artifact missing or empty: $rel"
      missing=1
    fi
  done

  if [[ "$RESTORE_ELASTICSEARCH" == true ]]; then
    if [[ ! -d "$backup_dir/elasticsearch" ]] || ! find "$backup_dir/elasticsearch" -type f -print -quit | grep -q .; then
      log "ERROR: Required Elasticsearch snapshot directory is missing or empty: elasticsearch/"
      missing=1
    fi
  fi

  if [[ $missing -ne 0 ]]; then
    exit 1
  fi

  if [[ "$RESTORE_KEYCLOAK" == true ]]; then
    gzip -t "$backup_dir/keycloak.sql.gz" || { log "ERROR: Keycloak dump is not valid gzip"; exit 1; }
  fi
  if [[ "$RESTORE_WEBMODELER" == true ]]; then
    gzip -t "$backup_dir/webmodeler.sql.gz" || { log "ERROR: Web Modeler dump is not valid gzip"; exit 1; }
  fi
  if [[ "$RESTORE_ORCHESTRATION" == true ]]; then
    tar tzf "$backup_dir/orchestration.tar.gz" >/dev/null || { log "ERROR: Orchestration archive is not readable"; exit 1; }
  fi
  if [[ "$RESTORE_CONFIGS" == true ]]; then
    tar tzf "$backup_dir/configs.tar.gz" >/dev/null || { log "ERROR: Config archive is not readable"; exit 1; }
  fi

  local archives_to_check=()
  [[ "$RESTORE_CONFIGS" == true ]] && archives_to_check+=("$backup_dir/configs.tar.gz")
  [[ "$RESTORE_ORCHESTRATION" == true ]] && archives_to_check+=("$backup_dir/orchestration.tar.gz")
  if [[ ${#archives_to_check[@]} -gt 0 ]]; then
    python3 - "${archives_to_check[@]}" <<'PYEOF' || {
import sys, tarfile

for archive in sys.argv[1:]:
    with tarfile.open(archive, "r:gz") as tf:
        for member in tf.getmembers():
            name = member.name.replace("\\", "/")
            if name.startswith("/") or name == ".." or name.startswith("../") or "/../" in name:
                print(f"ERROR: Unsafe tar path in {archive}: {member.name}")
                sys.exit(1)
PYEOF
      log "ERROR: Backup archive contains unsafe paths"
      exit 1
    }
  fi

  if [[ "$RESTORE_ELASTICSEARCH" == true ]]; then
    python3 - "$backup_dir/snapshot-info.json" <<'PYEOF' || {
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
snapshot = d.get("snapshot") or {}
if snapshot.get("state") != "SUCCESS":
    print(f"ERROR: Snapshot state is not SUCCESS: {snapshot.get('state', 'UNKNOWN')}")
    sys.exit(1)
if not (snapshot.get("name") or snapshot.get("snapshot")):
    print("ERROR: Snapshot name missing from snapshot-info.json")
    sys.exit(1)
PYEOF
      log "ERROR: Elasticsearch snapshot metadata is not restorable"
      exit 1
    }
  fi

  log "Required restore artifacts validated."
}

main() {
  parse_args "$@"
  configure_restore_components

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
  RESTORE_COMPOSE_CMD="$cmd"
  local restore_started_at
  restore_started_at="$(restore_start_timestamp)"

  LOG_FILE="$BACKUP_DIR/restore.log"
  mkdir -p "$BACKUP_BASE_DIR"
  acquire_lock

  log "Starting restore from: $BACKUP_DIR"
  log "Stage: $stage"
  log "Restore components: $RESTORE_COMPONENTS"
  [[ "$REHOST_KEYCLOAK" == true ]] && log "Keycloak rehost: enabled"
  [[ "$DEPRECATED_CREATE_BACKUP_USED" == true ]] && log "WARNING: --create-backup is deprecated; pre-restore backups are now created by default. Use --no-pre-backup to opt out."

  # Step 1: Pre-flight checks
  log "Running pre-flight checks..."

  if [[ ! -f "$BACKUP_DIR/manifest.json" ]]; then
    log "ERROR: Manifest not found in backup directory"
    exit 1
  fi

  if [[ "$TEST_MODE" == true ]]; then
    log "=== TEST MODE: Verifying backup integrity ==="
    verify_manifest "$BACKUP_DIR"
    validate_restore_inputs "$BACKUP_DIR"
    log "=== TEST MODE complete. Backup integrity verified. ==="
    release_lock
    exit 0
  fi

  verify_manifest "$BACKUP_DIR"
  validate_restore_inputs "$BACKUP_DIR"

  if [[ "$REHOST_KEYCLOAK" == true && "$RESTORE_KEYCLOAK" != true ]]; then
    log "ERROR: --rehost-keycloak requires the keycloak component to be restored."
    exit 1
  fi

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

    if [[ -n "$manifest_elastic_version" ]]; then
      if [[ "$manifest_elastic_version" != "${ELASTIC_VERSION:-}" ]]; then
        log "ERROR: Elasticsearch version mismatch. Backup: $manifest_elastic_version, Current: ${ELASTIC_VERSION:-}"
        exit 1
      fi
    else
      log "ERROR: Elasticsearch version not found in manifest. Cannot verify cross-cluster compatibility."
      exit 1
    fi

    if [[ -n "$manifest_camunda_version" ]]; then
      if [[ "$manifest_camunda_version" != "${CAMUNDA_VERSION:-}" ]]; then
        log "ERROR: Camunda version mismatch. Backup: $manifest_camunda_version, Current: ${CAMUNDA_VERSION:-}"
        exit 1
      fi
    else
      log "ERROR: Camunda version not found in manifest. Cannot verify cross-cluster compatibility."
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
    if [[ "$RESTORE_ALL" == true ]]; then
      echo "WARNING: This will OVERWRITE ALL current data in the Camunda stack!"
    else
      echo "WARNING: This will OVERWRITE selected Camunda data only: $RESTORE_COMPONENTS"
      echo "Granular restores do not guarantee a globally consistent stack timestamp."
    fi
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
  if [[ "$CREATE_PRE_BACKUP" == true && "$DRY_RUN" == false && "$TEST_MODE" == false ]]; then
    release_lock
    log "Creating pre-restore backup of current state..."
    local pre_restore_log
    pre_restore_log="$BACKUP_BASE_DIR/pre-restore-backup.log"
    if bash "$SCRIPT_DIR/backup.sh" > "$pre_restore_log" 2>&1; then
      log "Pre-restore backup completed. Log: $pre_restore_log"
      PRE_RESTORE_BACKUP_PATH="$(grep -E 'Backup completed successfully:' "$pre_restore_log" | tail -n 1 | sed 's/^.*Backup completed successfully: //')"
    else
      log "ERROR: Pre-restore backup failed. Aborting restore. Log: $pre_restore_log"
      acquire_lock
      exit 1
    fi
    acquire_lock
  elif [[ "$CREATE_PRE_BACKUP" == false ]]; then
    log "Pre-restore backup disabled by --no-pre-backup."
  fi

  # Step 2c: Collect pre-restore Elasticsearch state for later comparison
  local state_before="$BACKUP_DIR/restore-state-before.json"
  local state_after="$BACKUP_DIR/restore-state-after.json"
  if [[ "$DRY_RUN" == true ]]; then
    [[ "$RESTORE_ELASTICSEARCH" == true ]] && log "[DRY-RUN] Would collect Elasticsearch state (before)"
  else
    [[ "$RESTORE_ELASTICSEARCH" == true ]] && collect_es_state "before" "$state_before" || true
  fi

  # Step 3: Stop stack
  log "Stopping Camunda stack..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would run: $cmd down --remove-orphans"
  else
    $cmd down --remove-orphans
    STACK_DOWN_FOR_RESTORE=true
  fi

  # Step 4: Remove volumes (except keycloak-theme)
  log "Removing data volumes..."
  if [[ "$DRY_RUN" == true ]]; then
    if [[ "$RESTORE_ALL" == true ]]; then
      log "[DRY-RUN] Would remove volumes: orchestration, elastic, postgres, postgres-web"
    elif [[ "$RESTORE_ORCHESTRATION" == true ]]; then
      log "[DRY-RUN] Would remove volume: orchestration"
    else
      log "[DRY-RUN] Would keep existing Docker data volumes"
    fi
    log "[DRY-RUN] Would keep volume: keycloak-theme"
  else
    local proj
    proj="$(get_compose_project_name)"
    if [[ "$RESTORE_ALL" == true ]]; then
      docker volume rm "${proj}_orchestration" "${proj}_elastic" "${proj}_postgres" "${proj}_postgres-web" 2>/dev/null || true
      log "Volumes removed."
    elif [[ "$RESTORE_ORCHESTRATION" == true ]]; then
      docker volume rm "${proj}_orchestration" 2>/dev/null || true
      log "Orchestration volume removed."
    else
      log "No Docker data volumes removed for granular restore."
    fi
  fi

  # Step 5: Start only the services needed for data restore.
  # Starting the full stack here allows Camunda apps to recreate indices
  # before the Elasticsearch snapshot restore runs.
  log "Starting core services with fresh volumes..."
  if [[ "$DRY_RUN" == true ]]; then
    local core_services=()
    [[ "$RESTORE_KEYCLOAK" == true ]] && core_services+=("postgres")
    [[ "$RESTORE_WEBMODELER" == true ]] && core_services+=("web-modeler-db")
    [[ "$RESTORE_ELASTICSEARCH" == true ]] && core_services+=("elasticsearch")
    if [[ ${#core_services[@]} -gt 0 ]]; then
      log "[DRY-RUN] Would run: $cmd up -d ${core_services[*]}"
    else
      log "[DRY-RUN] No core services needed before data restore"
    fi
  else
    local core_services=()
    [[ "$RESTORE_KEYCLOAK" == true ]] && core_services+=("postgres")
    [[ "$RESTORE_WEBMODELER" == true ]] && core_services+=("web-modeler-db")
    [[ "$RESTORE_ELASTICSEARCH" == true ]] && core_services+=("elasticsearch")
    if [[ ${#core_services[@]} -gt 0 ]]; then
      $cmd up -d "${core_services[@]}"
    fi
  fi

  # Step 6: Wait for Postgres and Elasticsearch
  if [[ "$DRY_RUN" == false ]]; then
    if [[ "$RESTORE_KEYCLOAK" == true ]]; then
      wait_for_service "postgres" || exit 1
    fi
    if [[ "$RESTORE_WEBMODELER" == true ]]; then
      wait_for_service "web-modeler-db" || exit 1
    fi
    if [[ "$RESTORE_ELASTICSEARCH" == true ]]; then
      wait_for_service "elasticsearch" || exit 1
    fi
    log "Core services are healthy."
  else
    if [[ ${#core_services[@]} -gt 0 ]]; then
      log "[DRY-RUN] Would wait for services to be healthy: ${core_services[*]}"
    else
      log "[DRY-RUN] No core services to wait for"
    fi
  fi

  # Step 7: Restore Postgres databases
  if [[ "$RESTORE_KEYCLOAK" == true ]]; then
  log "Restoring Keycloak database..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would restore Keycloak DB from: $BACKUP_DIR/keycloak.sql.gz"
    [[ "$REHOST_KEYCLOAK" == true ]] && log "[DRY-RUN] Would rehost Keycloak clients to HOST=$HOST and local client secrets"
    log "[DRY-RUN] Would run ANALYZE on Keycloak DB"
  else
    if [[ -f "$BACKUP_DIR/keycloak.sql.gz" ]]; then
      local pg_stderr
      pg_stderr="$(mktemp)"
      if ! gunzip -c "$BACKUP_DIR/keycloak.sql.gz" | docker exec -i postgres pg_restore \
        -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --clean --if-exists 2>"$pg_stderr"; then
        log "ERROR: Keycloak pg_restore failed. stderr:"
        while IFS= read -r line; do
          log "  $line"
        done < "$pg_stderr"
        rm -f "$pg_stderr"
        exit 1
      fi
      rm -f "$pg_stderr"
      log "Keycloak database restored."
      if [[ "$REHOST_KEYCLOAK" == true ]]; then
        rehost_keycloak_clients
      fi
      # pg_restore does not restore planner statistics; run ANALYZE so the
      # first queries after restore use good plans instead of waiting for
      # autovacuum (see docs/backup-restore.md).
      log "Refreshing Keycloak DB planner statistics (ANALYZE)..."
      docker exec postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
        -c "ANALYZE;" >/dev/null 2>&1 || { log "ERROR: ANALYZE on Keycloak DB failed"; exit 1; }
    else
      log "ERROR: Keycloak backup not found."
      exit 1
    fi
  fi
  else
    log "Skipping Keycloak database restore."
  fi

  if [[ "$RESTORE_WEBMODELER" == true ]]; then
  log "Restoring Web Modeler database..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would restore Web Modeler DB from: $BACKUP_DIR/webmodeler.sql.gz"
    log "[DRY-RUN] Would run ANALYZE on Web Modeler DB"
  else
    if [[ -f "$BACKUP_DIR/webmodeler.sql.gz" ]]; then
      local pg_stderr
      pg_stderr="$(mktemp)"
      if ! gunzip -c "$BACKUP_DIR/webmodeler.sql.gz" | docker exec -i web-modeler-db pg_restore \
        -U "${WEBMODELER_DB_USER}" -d "${WEBMODELER_DB_NAME}" --clean --if-exists 2>"$pg_stderr"; then
        log "ERROR: Web Modeler pg_restore failed. stderr:"
        while IFS= read -r line; do
          log "  $line"
        done < "$pg_stderr"
        rm -f "$pg_stderr"
        exit 1
      fi
      rm -f "$pg_stderr"
      log "Web Modeler database restored."
      log "Refreshing Web Modeler DB planner statistics (ANALYZE)..."
      docker exec web-modeler-db psql -U "${WEBMODELER_DB_USER}" -d "${WEBMODELER_DB_NAME}" \
        -c "ANALYZE;" >/dev/null 2>&1 || { log "ERROR: ANALYZE on Web Modeler DB failed"; exit 1; }
    else
      log "ERROR: Web Modeler backup not found."
      exit 1
    fi
  fi
  else
    log "Skipping Web Modeler database restore."
  fi

  # Only core services are running at this point, so no Camunda apps can
  # recreate Elasticsearch indices before the snapshot restore.
  log "Camunda application services remain stopped until restore is complete."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would keep orchestration, identity, optimize, console, keycloak, and web-modeler app services stopped"
  fi

  # Step 8: Restore Elasticsearch
  if [[ "$RESTORE_ELASTICSEARCH" == true ]]; then
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
      local es_backup_volume
      es_backup_volume="${ES_BACKUP_VOLUME:-elastic-backup}"
      log "Copying snapshot data into Docker volume '$es_backup_volume'..."
      docker run --rm \
        -v "$es_backup_dir:/source:ro" \
        -v "${es_backup_volume}:/dest" \
        alpine sh -c 'rm -rf /dest/* && cp -r /source/. /dest/' > /dev/null 2>&1 || {
          log "ERROR: Could not copy snapshot data to volume"
          exit 1
        }
      log "Snapshot data copied to volume '$es_backup_volume'."
    else
      log "ERROR: Elasticsearch backup directory not found at $es_backup_dir."
      exit 1
    fi

    sleep 2

    # Register snapshot repo
    local es_host es_port es_url
    es_host="${ES_HOST:-localhost}"
    es_port="${ES_PORT:-9200}"
    es_url="http://${es_host}:${es_port}"
    local es_repo_body
    es_repo_body='{"type":"fs","settings":{"location":"/usr/share/elasticsearch/backup","compress":true}}'
    local repo_response
    repo_response="$(curl -s -X PUT "${es_url}/_snapshot/backup-repo" \
      -H 'Content-Type: application/json' \
      -d "$es_repo_body" 2>/dev/null || true)"
    if ! python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('acknowledged') else 1)" "$repo_response" > /dev/null 2>&1; then
      log "ERROR: Could not register snapshot repo: $repo_response"
      exit 1
    fi

    # Verify the snapshot exists BEFORE deleting any indices, so a wrong or
    # incomplete backup directory cannot wipe the live cluster.
    local snapshot_check_code
    snapshot_check_code="$(curl -s -o /dev/null -w '%{http_code}' "${es_url}/_snapshot/backup-repo/${snapshot_name}" 2>/dev/null || echo "000")"
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
      curl -s -X DELETE "${es_url}/${idx}" > /dev/null || true
    done < <(curl -s "${es_url}/_cat/indices?h=index&expand_wildcards=all" 2>/dev/null | grep -E "$camunda_regex" || true)

    log "Clearing Camunda-related Elasticsearch data streams..."
    local ds_tmp
    ds_tmp="$(mktemp)"
    curl -s "${es_url}/_data_stream?expand_wildcards=all" > "$ds_tmp" 2>/dev/null || true
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
        curl -s -X DELETE "${es_url}/_data_stream/${ds}" > /dev/null || true
      done <<< "$data_streams"
    fi
    sleep 2

    # Restore snapshot
    log "Restoring snapshot: $snapshot_name"
    local restore_response
    local restore_body='{"indices":"*,-.logs-*,-.ds-.logs-*,-ilm-history-*,-.ds-ilm-history-*","ignore_unavailable":true,"include_global_state":true}'
    restore_response="$(curl -s -X POST "${es_url}/_snapshot/backup-repo/${snapshot_name}/_restore?wait_for_completion=true" \
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
    elif d.get('snapshot', {}).get('shards', {}).get('failed', 0) == 0:
        print('SUCCESS')
    else:
        print('UNKNOWN')
except Exception as e:
    print('UNKNOWN')
" "$restore_response" 2>/dev/null || echo "UNKNOWN")"

    if [[ "$restore_status" == "SUCCESS" ]]; then
      log "Elasticsearch snapshot restored successfully."
    elif [[ "$restore_status" == ERROR* ]]; then
      log "ERROR: Elasticsearch restore failed: $restore_status"
      exit 1
    else
      log "ERROR: Elasticsearch restore state: $restore_status"
      exit 1
    fi
  fi
  else
    log "Skipping Elasticsearch restore."
  fi

  # Step 9: Restore Zeebe state
  if [[ "$RESTORE_ORCHESTRATION" == true ]]; then
  log "Restoring Zeebe state..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would run: $cmd create orchestration"
    log "[DRY-RUN] Would restore Zeebe state from: $BACKUP_DIR/orchestration.tar.gz"
  else
    if [[ -f "$BACKUP_DIR/orchestration.tar.gz" ]]; then
      local zeebe_vol
      zeebe_vol="$(compose_volume_name orchestration)"
      $cmd create orchestration >>"$LOG_FILE" 2>&1
      if ! docker volume inspect "$zeebe_vol" > /dev/null 2>>"$LOG_FILE"; then
        log "ERROR: Zeebe volume '$zeebe_vol' missing after compose create"
        exit 1
      fi
      docker run --rm \
        -v "${zeebe_vol}:/data" \
        -v "$BACKUP_DIR:/backup" \
        alpine sh -c "cd /data && tar xzf /backup/orchestration.tar.gz"
      log "Zeebe state restored."
    else
      log "ERROR: Orchestration backup not found."
      exit 1
    fi
  fi
  else
    log "Skipping Zeebe state restore."
  fi

  # Step 10: Restore configs
  if [[ "$RESTORE_CONFIGS" == true ]]; then
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
        log "ERROR: Config backup not found."
        exit 1
      fi
    fi
  fi
  else
    log "Skipping configuration restore."
  fi

  # Step 11: Restart stack
  log "Restarting stack..."
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would run: $cmd up -d"
  else
    $cmd up -d
    STACK_DOWN_FOR_RESTORE=false
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
      log "ERROR: Some services are not healthy yet. Check with: docker compose ps"
      exit 1
    }

    # Collect post-restore state and compare to pre-restore state
    [[ "$RESTORE_ELASTICSEARCH" == true ]] && collect_es_state "after" "$state_after" || true
    [[ "$RESTORE_ELASTICSEARCH" == true ]] && compare_es_state "$state_before" "$state_after" || true
    cleanup_dangling_compose_volumes "$restore_started_at" || true

    log "Restore completed successfully."
  fi

  release_lock
}

main "$@"
