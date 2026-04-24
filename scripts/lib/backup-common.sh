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

restore_start_timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

cleanup_dangling_compose_volumes() {
  local restore_started_at="$1"
  local project_name="${2:-$(get_compose_project_name)}"

  log "Cleaning up dangling Docker volumes from previous restore runs..."

  local dangling_volumes
  dangling_volumes="$(docker volume ls -q -f dangling=true 2>/dev/null || true)"
  if [[ -z "$dangling_volumes" ]]; then
    log "No dangling Docker volumes found."
    return 0
  fi

  local removed=0
  while IFS= read -r volume_name; do
    [[ -z "$volume_name" ]] && continue
    [[ "$volume_name" == "elastic-backup" ]] && continue

    local inspect_json
    inspect_json="$(docker volume inspect "$volume_name" 2>/dev/null || true)"
    [[ -z "$inspect_json" ]] && continue

    local decision
    decision="$(python3 -c '
import json, sys
from datetime import datetime, timezone

project_name = sys.argv[1]
restore_started_at = sys.argv[2]
inspect_json = sys.argv[3]

try:
    restore_dt = datetime.strptime(restore_started_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
except ValueError:
    print("skip")
    raise SystemExit

try:
    payload = json.loads(inspect_json)
    item = payload[0] if isinstance(payload, list) and payload else payload
except Exception:
    print("skip")
    raise SystemExit

labels = item.get("Labels") or {}
if labels.get("com.docker.compose.project") != project_name:
    print("skip")
    raise SystemExit

created_raw = item.get("CreatedAt") or ""
created_main = created_raw.split(".")[0]
try:
    created_dt = datetime.strptime(created_main, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
except ValueError:
    try:
        created_dt = datetime.fromisoformat(created_raw.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        print("skip")
        raise SystemExit

print("remove" if created_dt <= restore_dt else "skip")
' "$project_name" "$restore_started_at" "$inspect_json" 2>/dev/null || true)"

    if [[ "$decision" != "remove" ]]; then
      continue
    fi

    if docker volume rm "$volume_name" > /dev/null 2>&1; then
      removed=$((removed + 1))
      log "Removed dangling volume: $volume_name"
    else
      log "WARNING: Could not remove dangling volume $volume_name"
    fi
  done <<< "$dangling_volumes"

  log "Dangling volume cleanup removed $removed volume(s)."
}

collect_es_state() {
  local phase="$1"
  local output_file="$2"

  log "Collecting Elasticsearch state ($phase)..."

  local health_json indices_json data_streams_json
  health_json="$(curl -s --max-time 10 http://localhost:9200/_cluster/health 2>/dev/null || true)"

  if [[ -z "$health_json" ]] || ! python3 -c "import json,sys; json.loads(sys.argv[1])" "$health_json" > /dev/null 2>&1; then
    python3 - "$output_file" "$phase" <<'PYEOF' 2>/dev/null || true
import json, sys
with open(sys.argv[1], 'w') as f:
    json.dump({'phase': sys.argv[2], 'reachable': False}, f, indent=2)
PYEOF
    log "  Elasticsearch not reachable."
    return 0
  fi

  indices_json="$(curl -s --max-time 15 'http://localhost:9200/_cat/indices?h=index,docs.count,store.size&format=json&expand_wildcards=all' 2>/dev/null || echo '[]')"
  data_streams_json="$(curl -s --max-time 10 'http://localhost:9200/_data_stream?expand_wildcards=all' 2>/dev/null || echo '{}')"

  python3 - "$output_file" "$phase" "$health_json" "$indices_json" "$data_streams_json" <<'PYEOF' 2>/dev/null || true
import json, re, sys

output_file, phase, health_s, indices_s, data_streams_s = sys.argv[1:6]

pattern = re.compile(r'^(operate|tasklist|optimize|zeebe|camunda-|\.camunda|\.tasks)')

def safe_json(s, default):
    try:
        return json.loads(s)
    except Exception:
        return default

health = safe_json(health_s, {})
indices_raw = safe_json(indices_s, [])
data_streams_raw = safe_json(data_streams_s, {})

component_counts = {'operate': 0, 'tasklist': 0, 'optimize': 0, 'zeebe': 0, 'camunda': 0, 'other': 0}
total_docs = 0
indices = []
if isinstance(indices_raw, list):
    for row in indices_raw:
        name = row.get('index', '') if isinstance(row, dict) else ''
        if not name or not pattern.match(name):
            continue
        try:
            docs = int(row.get('docs.count') or 0)
        except (TypeError, ValueError):
            docs = 0
        size = row.get('store.size', '') if isinstance(row, dict) else ''
        indices.append({'name': name, 'docs': docs, 'size': size})
        total_docs += docs
        if name.startswith('operate'):
            component_counts['operate'] += 1
        elif name.startswith('tasklist'):
            component_counts['tasklist'] += 1
        elif name.startswith('optimize'):
            component_counts['optimize'] += 1
        elif name.startswith('zeebe'):
            component_counts['zeebe'] += 1
        elif name.startswith('camunda-') or name.startswith('.camunda'):
            component_counts['camunda'] += 1
        else:
            component_counts['other'] += 1

indices.sort(key=lambda x: x['name'])

data_streams = []
if isinstance(data_streams_raw, dict):
    for ds in data_streams_raw.get('data_streams', []) or []:
        name = ds.get('name', '') if isinstance(ds, dict) else ''
        if name and pattern.match(name):
            data_streams.append(name)
data_streams.sort()

state = {
    'phase': phase,
    'reachable': True,
    'cluster': {
        'name': health.get('cluster_name', ''),
        'status': health.get('status', ''),
        'number_of_nodes': health.get('number_of_nodes', 0),
        'active_shards': health.get('active_shards', 0),
    },
    'indices': indices,
    'data_streams': data_streams,
    'component_counts': component_counts,
    'total_camunda_indices': len(indices),
    'total_camunda_docs': total_docs,
}

with open(output_file, 'w') as f:
    json.dump(state, f, indent=2)
PYEOF

  if [[ -f "$output_file" ]]; then
    while IFS= read -r line; do
      log "$line"
    done < <(python3 - "$output_file" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
if not d.get('reachable'):
    print("  Elasticsearch not reachable.")
else:
    c = d.get('cluster', {})
    cc = d.get('component_counts', {})
    print(f"  Cluster: {c.get('name','?')} ({c.get('status','?')}, {c.get('number_of_nodes','?')} node(s))")
    print(f"  Camunda indices: {d.get('total_camunda_indices',0)} ({d.get('total_camunda_docs',0)} total docs)")
    print(f"    operate={cc.get('operate',0)}, tasklist={cc.get('tasklist',0)}, optimize={cc.get('optimize',0)}, zeebe={cc.get('zeebe',0)}, camunda={cc.get('camunda',0)}, other={cc.get('other',0)}")
    print(f"  Data streams: {len(d.get('data_streams',[]))}")
PYEOF
)
  fi
}

compare_es_state() {
  local before_file="$1"
  local after_file="$2"

  if [[ ! -f "$before_file" || ! -f "$after_file" ]]; then
    log "WARNING: ES state comparison skipped (missing state files)."
    return 0
  fi

  log "=== Elasticsearch state comparison (before -> after) ==="
  while IFS= read -r line; do
    log "$line"
  done < <(python3 - "$before_file" "$after_file" <<'PYEOF' 2>/dev/null || true
import json, sys

try:
    with open(sys.argv[1]) as f: before = json.load(f)
    with open(sys.argv[2]) as f: after = json.load(f)
except Exception:
    print("  (Could not read state files)")
    sys.exit(0)

def reach(s): return "reachable" if s.get('reachable') else "UNREACHABLE"

print(f"  Connectivity: {reach(before)} -> {reach(after)}")

if not before.get('reachable') or not after.get('reachable'):
    print("  (Skipping detailed comparison due to unreachable state)")
    sys.exit(0)

bc = before.get('cluster', {})
ac = after.get('cluster', {})
print(f"  Cluster status: {bc.get('status','?')} -> {ac.get('status','?')}")
print(f"  Nodes:          {bc.get('number_of_nodes','?')} -> {ac.get('number_of_nodes','?')}")
print(f"  Active shards:  {bc.get('active_shards','?')} -> {ac.get('active_shards','?')}")

print(f"  Camunda indices: {before.get('total_camunda_indices',0)} -> {after.get('total_camunda_indices',0)}")
print(f"  Camunda docs:    {before.get('total_camunda_docs',0)} -> {after.get('total_camunda_docs',0)}")

bcc = before.get('component_counts', {})
acc = after.get('component_counts', {})
for k in ('operate','tasklist','optimize','zeebe','camunda','other'):
    print(f"    {k:9s} {bcc.get(k,0)} -> {acc.get(k,0)}")

print(f"  Data streams:    {len(before.get('data_streams',[]))} -> {len(after.get('data_streams',[]))}")

before_idx = {i['name']: i for i in before.get('indices', [])}
after_idx  = {i['name']: i for i in after.get('indices', [])}

only_before = sorted(set(before_idx) - set(after_idx))
only_after  = sorted(set(after_idx) - set(before_idx))

MAX = 20
if only_before:
    print(f"  Indices removed ({len(only_before)}):")
    for n in only_before[:MAX]:
        print(f"    - {n} ({before_idx[n].get('docs',0)} docs)")
    if len(only_before) > MAX:
        print(f"    ... and {len(only_before)-MAX} more")

if only_after:
    print(f"  Indices added ({len(only_after)}):")
    for n in only_after[:MAX]:
        print(f"    + {n} ({after_idx[n].get('docs',0)} docs)")
    if len(only_after) > MAX:
        print(f"    ... and {len(only_after)-MAX} more")

changed = []
for n in sorted(set(before_idx) & set(after_idx)):
    bd = before_idx[n].get('docs', 0)
    ad = after_idx[n].get('docs', 0)
    if bd != ad:
        changed.append((n, bd, ad))
if changed:
    print(f"  Indices with doc count changes ({len(changed)}):")
    for n, bd, ad in changed[:MAX]:
        delta = ad - bd
        sign = '+' if delta >= 0 else ''
        print(f"    ~ {n}: {bd} -> {ad} ({sign}{delta})")
    if len(changed) > MAX:
        print(f"    ... and {len(changed)-MAX} more")

print("========================================================")
PYEOF
)
}

trap cleanup_on_error EXIT
