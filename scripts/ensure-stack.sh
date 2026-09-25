#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
CREDENTIALS_FILE="$PROJECT_DIR/.env-credentials"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

if [[ ! -f "$ENV_FILE" && ! -f "$CREDENTIALS_FILE" ]]; then
  log "ERROR: .env file not found. Run: cp .env.example .env"
  exit 1
fi

set -a
# shellcheck source=/dev/null
for source_file in "$ENV_FILE" "$CREDENTIALS_FILE"; do
  [[ -f "$source_file" ]] || continue
  source "$source_file"
done
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

# Same DISPLAY_STAGE fallback as scripts/start.sh, so a restarted service
# (e.g. hub's HUB_CLUSTER_TAG) gets the same configuration as on a normal start.
export DISPLAY_STAGE="${DISPLAY_STAGE:-$stage}"

compose_cmd=(docker compose)
for env_file in "$ENV_FILE" "$CREDENTIALS_FILE"; do
  [[ -f "$env_file" ]] && compose_cmd+=(--env-file "$env_file")
done
compose_cmd+=(
  -f "$PROJECT_DIR/docker-compose.yaml"
  -f "$PROJECT_DIR/stages/${stage}.yaml"
)

if ! config_services="$("${compose_cmd[@]}" config --services 2>&1)"; then
  log "ERROR: Could not determine expected services from docker compose config"
  printf '%s\n' "$config_services" >&2
  exit 1
fi

# camunda-data-init is a one-shot init container that exits after its work;
# it is started as a dependency of orchestration and must not be restarted here.
mapfile -t expected_services < <(printf '%s\n' "$config_services" | grep -vx -e '' -e 'camunda-data-init')
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
