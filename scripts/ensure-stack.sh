#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

if [[ ! -f "$ENV_FILE" ]]; then
  log "ERROR: .env file not found. Run: cp .env.example .env"
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

stage="$(printf '%s' "${STAGE:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

case "$stage" in
  prod|dev|test)
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

if ! docker info >/dev/null 2>&1; then
  log "ERROR: Docker daemon is not reachable"
  exit 1
fi

compose_cmd=(
  docker compose
  -f "$PROJECT_DIR/docker-compose.yaml"
  -f "$PROJECT_DIR/stages/${stage}.yaml"
)

mapfile -t expected_services < <("${compose_cmd[@]}" config --services)
mapfile -t running_services < <("${compose_cmd[@]}" ps --services --status running)

missing_services=()

for service in "${expected_services[@]}"; do
  if ! printf '%s\n' "${running_services[@]}" | grep -Fxq "$service"; then
    missing_services+=("$service")
  fi
done

if [[ ${#missing_services[@]} -eq 0 ]]; then
  log "All expected services are running for STAGE=$stage"
  exit 0
fi

log "Detected missing or stopped services for STAGE=$stage: ${missing_services[*]}"
log "Starting only the missing or stopped services"
"${compose_cmd[@]}" up -d "${missing_services[@]}"
