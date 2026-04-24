#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

DRILL_DIR="$PROJECT_DIR/backups/.drill"
DRILL_ENV="$DRILL_DIR/.env.drill"
DRILL_PORTS="$DRILL_DIR/ports.yaml"
DRILL_PROJECT_NAME="${DRILL_PROJECT_NAME:-camunda-restoredrill}"
DRILL_HOST="${DRILL_HOST:-drill.localhost}"
DRILL_PORT_OFFSET="${DRILL_PORT_OFFSET:-10000}"

log_drill() {
  echo "[drill] $*"
}

generate_drill_env() {
  local source_env="$PROJECT_DIR/.env"
  if [[ ! -f "$source_env" ]]; then
    log_drill "ERROR: .env not found at $source_env"
    exit 1
  fi

  mkdir -p "$DRILL_DIR"

  cp "$source_env" "$DRILL_ENV"

  if grep -q '^HOST=' "$DRILL_ENV"; then
    sed -i "s/^HOST=.*/HOST=$DRILL_HOST/" "$DRILL_ENV"
  else
    echo "HOST=$DRILL_HOST" >> "$DRILL_ENV"
  fi

  if grep -q '^COMPOSE_PROJECT_NAME=' "$DRILL_ENV"; then
    sed -i "s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=$DRILL_PROJECT_NAME/" "$DRILL_ENV"
  else
    echo "COMPOSE_PROJECT_NAME=$DRILL_PROJECT_NAME" >> "$DRILL_ENV"
  fi

  local es_port=$((9200 + DRILL_PORT_OFFSET))
  if grep -q '^ES_PORT=' "$DRILL_ENV"; then
    sed -i "s/^ES_PORT=.*/ES_PORT=$es_port/" "$DRILL_ENV"
  else
    echo "ES_PORT=$es_port" >> "$DRILL_ENV"
  fi

  if grep -q '^ES_BACKUP_VOLUME=' "$DRILL_ENV"; then
    sed -i "s/^ES_BACKUP_VOLUME=.*/ES_BACKUP_VOLUME=elastic-backup-drill/" "$DRILL_ENV"
  else
    echo "ES_BACKUP_VOLUME=elastic-backup-drill" >> "$DRILL_ENV"
  fi

  cat > "$DRILL_PORTS" <<EOF
services:
  orchestration:
    ports:
      - "$((26500 + DRILL_PORT_OFFSET)):26500"
      - "$((9600 + DRILL_PORT_OFFSET)):9600"
      - "$((8088 + DRILL_PORT_OFFSET)):8080"
  connectors:
    ports:
      - "$((8086 + DRILL_PORT_OFFSET)):8080"
  optimize:
    ports:
      - "$((8083 + DRILL_PORT_OFFSET)):8090"
  identity:
    ports:
      - "$((8084 + DRILL_PORT_OFFSET)):8084"
  elasticsearch:
    ports:
      - "$((9200 + DRILL_PORT_OFFSET)):9200"
      - "$((9300 + DRILL_PORT_OFFSET)):9300"
  web-modeler-db:
    ports:
      - "$((1025 + DRILL_PORT_OFFSET)):1025"
      - "$((8075 + DRILL_PORT_OFFSET)):8025"
  web-modeler-webapp:
    ports:
      - "$((8070 + DRILL_PORT_OFFSET)):8070"
  web-modeler-websockets:
    ports:
      - "$((8060 + DRILL_PORT_OFFSET)):8060"
  console:
    ports:
      - "$((8087 + DRILL_PORT_OFFSET)):8080"
      - "$((9100 + DRILL_PORT_OFFSET)):9100"
  reverse-proxy:
    ports:
      - "$((443 + DRILL_PORT_OFFSET)):443"
EOF

  log_drill "Generated drill env: $DRILL_ENV"
  log_drill "Generated port remap: $DRILL_PORTS"
}

run_drill_stack_up() {
  local backup_dir="$1"

  export ENV_FILE="$DRILL_ENV"
  export COMPOSE_FILE="$PROJECT_DIR/docker-compose.yaml:$PROJECT_DIR/stages/drill.yaml:$DRILL_PORTS"
  export ES_BACKUP_VOLUME="elastic-backup-drill"

  log_drill "Running restore.sh against drill stack..."
  bash "$SCRIPT_DIR/../restore.sh" --force --no-pre-backup --env-file "$DRILL_ENV" "$backup_dir"
}

run_smoke_tests() {
  local offset="${DRILL_PORT_OFFSET}"
  local keycloak_port=$((18080 + offset))
  local orchestration_port=$((8088 + offset))
  local webmodeler_port=$((8070 + offset))

  local timeout=120
  local elapsed=0
  local interval=5

  log_drill "Running smoke tests (timeout ${timeout}s)..."

  local keycloak_url="http://localhost:${keycloak_port}/auth/realms/camunda-platform"
  elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if curl -s -o /dev/null -w '%{http_code}' "$keycloak_url" 2>/dev/null | grep -q '^200$'; then
      log_drill "  Keycloak realm: OK"
      break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  if [[ $elapsed -ge $timeout ]]; then
    log_drill "  Keycloak realm: FAILED"
    return 1
  fi

  local orch_url="http://localhost:${orchestration_port}/actuator/health"
  elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local orch_status
    orch_status="$(curl -s "$orch_url" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("status","DOWN"))' 2>/dev/null || echo "DOWN")"
    if [[ "$orch_status" == "UP" ]]; then
      log_drill "  Orchestration health: OK"
      break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  if [[ $elapsed -ge $timeout ]]; then
    log_drill "  Orchestration health: FAILED"
    return 1
  fi

  local wm_url="http://localhost:${webmodeler_port}/health/readiness"
  elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if curl -s -o /dev/null -w '%{http_code}' "$wm_url" 2>/dev/null | grep -q '^200$'; then
      log_drill "  Web Modeler readiness: OK"
      break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  if [[ $elapsed -ge $timeout ]]; then
    log_drill "  Web Modeler readiness: FAILED"
    return 1
  fi

  if [[ -n "${DRILL_KNOWN_PROJECT_ID:-}" ]]; then
    local proj_url="http://localhost:${webmodeler_port}/internal-api/projects/${DRILL_KNOWN_PROJECT_ID}"
    elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
      if curl -s -o /dev/null -w '%{http_code}' "$proj_url" 2>/dev/null | grep -q '^200$'; then
        log_drill "  Known project API: OK"
        break
      fi
      sleep "$interval"
      elapsed=$((elapsed + interval))
    done
    if [[ $elapsed -ge $timeout ]]; then
      log_drill "  Known project API: FAILED"
      return 1
    fi
  fi

  log_drill "All smoke tests passed."
  return 0
}

teardown_drill_stack() {
  log_drill "Tearing down drill stack..."
  local cmd
  cmd="docker compose -p $DRILL_PROJECT_NAME"
  $cmd down --volumes --remove-orphans 2>/dev/null || true

  docker volume prune --filter label=com.docker.compose.project=$DRILL_PROJECT_NAME --force 2>/dev/null || true

  if [[ -d "$DRILL_DIR" ]]; then
    rm -rf "$DRILL_DIR"
    log_drill "Removed drill temp directory: $DRILL_DIR"
  fi

  log_drill "Teardown complete."
}
