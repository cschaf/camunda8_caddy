#!/usr/bin/env bash
#
# SYNOPSIS
#     Wipe the local Camunda stack for a clean reinstall.
#
# DESCRIPTION
#     Stops the stack and removes its containers, networks, data volumes and
#     images, so the next start performs a fresh initialisation.
#
#     Project files are NEVER touched: .env, .env-credentials,
#     connector-secrets.txt, Caddyfile, certs/, secrets/, .hub/,
#     .orchestration/ and backups/ stay exactly as they are.
#
#     DESTRUCTIVE: by default all state is deleted (Zeebe, Postgres/Keycloak,
#     Elasticsearch, Hub DB). Use --keep-volumes to preserve the data volumes.
#     You must type WIPE to confirm unless --yes is passed.
#
# EXAMPLES
#     bash scripts/cluster-wipe.sh --dry-run
#     bash scripts/cluster-wipe.sh
#     bash scripts/cluster-wipe.sh --yes
#     bash scripts/cluster-wipe.sh --yes --keep-volumes
#     bash scripts/cluster-wipe.sh --yes --prune-build
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
CREDENTIALS_FILE="$PROJECT_DIR/.env-credentials"

DRY_RUN=false
ASSUME_YES=false
KEEP_VOLUMES=false
KEEP_IMAGES=false
PRUNE_BUILD=false

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --dry-run        Show what would be removed, change nothing.
  --yes, -y        Skip the interactive WIPE confirmation.
  --keep-volumes   Keep data volumes (NOT a clean reinstall).
  --keep-images    Keep the Docker images (only remove containers/networks).
  --prune-build    Also prune the global Docker build cache (affects other projects).
  -h, --help       Show this help.

By default this removes: containers, project networks, data volumes and the
stack's images. Files per stack (.env, .env-credentials, configs, backups/)
are kept.
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    --keep-volumes) KEEP_VOLUMES=true; shift ;;
    --keep-images) KEEP_IMAGES=true; shift ;;
    --prune-build) PRUNE_BUILD=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

for f in "$ENV_FILE" "$CREDENTIALS_FILE"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: $f not found." >&2
    echo "This script keeps your env files and needs them to resolve the stack." >&2
    exit 1
  fi
done

STAGE_RAW="$(grep -E '^[[:space:]]*STAGE[[:space:]]*=' "$ENV_FILE" | head -n1 | cut -d= -f2-)"
STAGE="$(printf '%s' "$STAGE_RAW" | tr -d '\r' | tr -d '[:space:]' | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]')"
if [[ -z "$STAGE" ]]; then
  echo "ERROR: STAGE not found in $ENV_FILE" >&2
  exit 1
fi
STAGE_FILE="$PROJECT_DIR/stages/$STAGE.yaml"
if [[ ! -f "$STAGE_FILE" ]]; then
  echo "ERROR: stage file not found: $STAGE_FILE" >&2
  exit 1
fi

COMPOSE=(docker compose --env-file "$ENV_FILE" --env-file "$CREDENTIALS_FILE" -f "$PROJECT_DIR/docker-compose.yaml" -f "$STAGE_FILE")

# Fixed container_name values from docker-compose.yaml. Used as a safety net in
# case a stale/orphaned container survived `compose down`.
CONTAINERS=(
  camunda-data-init orchestration connectors optimize identity postgres
  camunda-db keycloak elasticsearch web-modeler-db mailpit hub
  hub-websockets autoheal reverse-proxy
)

echo "Camunda cluster wipe"
echo "  Project dir : $PROJECT_DIR"
echo "  STAGE       : $STAGE"
echo "  Volumes     : $([[ "$KEEP_VOLUMES" == true ]] && echo 'KEEP' || echo 'DELETE (data loss)')"
echo "  Images      : $([[ "$KEEP_IMAGES" == true ]] && echo 'KEEP' || echo 'DELETE')"
echo "  Build cache : $([[ "$PRUNE_BUILD" == true ]] && echo 'PRUNE (global)' || echo 'keep')"
echo ""
echo "Kept (never touched): .env, .env-credentials, connector-secrets.txt, Caddyfile,"
echo "                      certs/, secrets/, .hub/, .orchestration/, backups/"
echo ""

if [[ "$DRY_RUN" == true ]]; then
  DOWN_PREVIEW=(down --remove-orphans)
  [[ "$KEEP_VOLUMES" == false ]] && DOWN_PREVIEW+=(--volumes)
  [[ "$KEEP_IMAGES" == false ]] && DOWN_PREVIEW+=(--rmi all)
  echo "[dry-run] would run: ${COMPOSE[*]} ${DOWN_PREVIEW[*]}"
  echo "[dry-run] would remove leftover containers: ${CONTAINERS[*]}"
  [[ "$KEEP_IMAGES" == false ]] && echo "[dry-run] would remove images listed by: ${COMPOSE[*]} config --images"
  [[ "$KEEP_VOLUMES" == false ]] && echo "[dry-run] would remove the fixed-name volume: elastic-backup"
  [[ "$PRUNE_BUILD" == true ]] && echo "[dry-run] would run: docker builder prune -af"
  echo "[dry-run] nothing changed."
  exit 0
fi

if [[ "$ASSUME_YES" != true ]]; then
  echo "WARNING: This removes the stack's containers, networks and images."
  if [[ "$KEEP_VOLUMES" == false ]]; then
    echo "         It also DELETES the data volumes: Zeebe, Postgres/Keycloak,"
    echo "         Elasticsearch and Hub DB. There is no undo."
  fi
  echo ""
  read -r -p "Type WIPE to continue: " confirm
  if [[ "$confirm" != "WIPE" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

DOWN=(down --remove-orphans)
[[ "$KEEP_VOLUMES" == false ]] && DOWN+=(--volumes)
[[ "$KEEP_IMAGES" == false ]] && DOWN+=(--rmi all)

echo ">> Stopping and removing the stack..."
if ! "${COMPOSE[@]}" "${DOWN[@]}"; then
  echo "WARNING: 'docker compose down' returned non-zero; continuing with the cleanup steps."
fi

echo ">> Removing leftover containers..."
for c in "${CONTAINERS[@]}"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    if docker rm -f "$c" >/dev/null 2>&1; then
      echo "   removed container: $c"
    else
      echo "   could not remove container: $c"
    fi
  fi
done

if [[ "$KEEP_IMAGES" == false ]]; then
  echo ">> Removing stack images..."
  IMAGES="$("${COMPOSE[@]}" config --images 2>/dev/null | sort -u || true)"
  if [[ -n "$IMAGES" ]]; then
    while IFS= read -r img; do
      img="$(printf '%s' "$img" | tr -d '[:space:]')"
      [[ -z "$img" ]] && continue
      if docker rmi -f "$img" >/dev/null 2>&1; then
        echo "   removed image: $img"
      else
        echo "   skipped image (not present or in use): $img"
      fi
    done <<< "$IMAGES"
  else
    echo "   (could not resolve images via 'docker compose config --images'; skipping)"
  fi
fi

if [[ "$KEEP_VOLUMES" == false ]]; then
  # elastic-backup uses a fixed name (not project-prefixed); remove it explicitly
  # in case it outlived the compose project.
  if docker volume rm elastic-backup >/dev/null 2>&1; then
    echo "   removed volume: elastic-backup"
  fi
fi

if [[ "$PRUNE_BUILD" == true ]]; then
  echo ">> Pruning the global Docker build cache..."
  docker builder prune -af || true
fi

echo ""
echo "Done. The stack is wiped; your env files and configuration are untouched."
echo "Fresh install:"
echo "  bash scripts/setup-host.sh"
echo "  bash scripts/start.sh"
