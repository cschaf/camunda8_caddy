#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
CREDENTIALS_FILE="$PROJECT_DIR/.env-credentials"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env file not found. It is part of the repo, so this should not happen." >&2
  echo "       Re-clone the repository, or restore .env from your last commit." >&2
  exit 1
fi

if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  echo "ERROR: .env-credentials file not found." >&2
  echo "       Run one of:" >&2
  echo "         bash scripts/generate-secrets.sh             # generate strong random secrets" >&2
  echo "         cp .env-credentials.example .env-credentials # copy the demo template" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
source "$CREDENTIALS_FILE"
set +a

stage="$(printf '%s' "${STAGE:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

case "$stage" in
  prod|dev|test)
    ;;
  "")
    echo "ERROR: STAGE not found in .env. Expected one of: prod, dev, test" >&2
    exit 1
    ;;
  *)
    echo "ERROR: Unsupported STAGE '$stage'. Expected one of: prod, dev, test" >&2
    exit 1
    ;;
esac

display_stage="${DISPLAY_STAGE:-$stage}"
export DISPLAY_STAGE="$display_stage"

# Render console config from template
CONSOLE_TEMPLATE="$PROJECT_DIR/.console/application.yaml.template"
CONSOLE_CONFIG="$PROJECT_DIR/.console/application.yaml"
if [[ -f "$CONSOLE_TEMPLATE" ]]; then
  if command -v envsubst >/dev/null 2>&1; then
    envsubst '$HOST $DISPLAY_STAGE $CAMUNDA_VERSION $CAMUNDA_CONSOLE_VERSION $CAMUNDA_OPERATE_VERSION $CAMUNDA_TASKLIST_VERSION $CAMUNDA_OPTIMIZE_VERSION $CAMUNDA_IDENTITY_VERSION $KEYCLOAK_SERVER_VERSION $CAMUNDA_WEB_MODELER_VERSION $CAMUNDA_CONNECTORS_VERSION' < "$CONSOLE_TEMPLATE" > "$CONSOLE_CONFIG"
  else
    sed \
      -e "s/\\\${HOST}/$HOST/g" \
      -e "s/\\\${DISPLAY_STAGE}/$display_stage/g" \
      -e "s/\\\${CAMUNDA_VERSION}/$CAMUNDA_VERSION/g" \
      -e "s/\\\${CAMUNDA_CONSOLE_VERSION}/$CAMUNDA_CONSOLE_VERSION/g" \
      -e "s/\\\${CAMUNDA_OPERATE_VERSION}/$CAMUNDA_OPERATE_VERSION/g" \
      -e "s/\\\${CAMUNDA_TASKLIST_VERSION}/$CAMUNDA_TASKLIST_VERSION/g" \
      -e "s/\\\${CAMUNDA_OPTIMIZE_VERSION}/$CAMUNDA_OPTIMIZE_VERSION/g" \
      -e "s/\\\${CAMUNDA_IDENTITY_VERSION}/$CAMUNDA_IDENTITY_VERSION/g" \
      -e "s/\\\${KEYCLOAK_SERVER_VERSION}/$KEYCLOAK_SERVER_VERSION/g" \
      -e "s/\\\${CAMUNDA_WEB_MODELER_VERSION}/$CAMUNDA_WEB_MODELER_VERSION/g" \
      -e "s/\\\${CAMUNDA_CONNECTORS_VERSION}/$CAMUNDA_CONNECTORS_VERSION/g" \
      "$CONSOLE_TEMPLATE" > "$CONSOLE_CONFIG"
  fi
fi

# Render optimize config from template
OPTIMIZE_TEMPLATE="$PROJECT_DIR/.optimize/environment-config.yaml.example"
OPTIMIZE_CONFIG="$PROJECT_DIR/.optimize/environment-config.yaml"
if [[ -f "$OPTIMIZE_TEMPLATE" ]]; then
  sed "s/ELASTIC_PASSWORD_PLACEHOLDER/$ELASTIC_PASSWORD/g" "$OPTIMIZE_TEMPLATE" > "$OPTIMIZE_CONFIG"
fi

# Compose command prefix. Both .env (non-secret config) and .env-credentials
# (secrets) are loaded via --env-file so ${VAR} interpolation in
# docker-compose.yaml works for both files.
COMPOSE_BASE=(
  docker compose
  --env-file "$ENV_FILE"
  --env-file "$CREDENTIALS_FILE"
  -f "$PROJECT_DIR/docker-compose.yaml"
  -f "$PROJECT_DIR/stages/${stage}.yaml"
)

# Pre-flight: bring Elasticsearch up first so the Optimize schema check has
# something to talk to, then run the schema upgrade one-shot, then start the
# rest of the stack.
#
# Optimize persists its schema version in Elasticsearch and refuses to start
# when the stored version is older than its own binary. The upgrade is
# non-destructive and idempotent (it logs "no update to perform" if the stored
# version is already at or above the new binary), so running it on every
# start is safe. The upgrade MUST happen after ES is healthy but before
# optimize starts; otherwise either the pre-flight cannot reach ES (fresh
# start) or optimize boots with a stale schema and restart-loops until the
# operator manually runs the recovery script.
#
# `docker compose up -d elasticsearch` is idempotent: it is a no-op if ES is
# already running. The final `up -d` below will not restart the healthy ES.
#
# The `//optimize/...` leading double-slash is the Git Bash on Windows MSYS
# path translation workaround so the path is not rewritten to a Windows path
# before being passed into the container.

echo ">> Starting Elasticsearch (pre-flight dependency)..."
"${COMPOSE_BASE[@]}" up -d elasticsearch

echo ">> Waiting for Elasticsearch to become healthy (timeout 300s)..."
ATTEMPTS=0
MAX_ATTEMPTS=60
ES_HEALTHY=0
until [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; do
  if "${COMPOSE_BASE[@]}" ps elasticsearch 2>/dev/null | grep -q "(healthy)"; then
    ES_HEALTHY=1
    break
  fi
  ATTEMPTS=$((ATTEMPTS + 1))
  sleep 5
done

if [ "$ES_HEALTHY" -ne 1 ]; then
  echo "WARN: Elasticsearch did not become healthy in time. Skipping Optimize pre-flight." >&2
  echo "      If optimize does not come up, run: bash scripts/optimize-upgrade.sh" >&2
else
  echo ">> Pre-flight: Optimize schema check (idempotent)..."
  if ! "${COMPOSE_BASE[@]}" \
      run --rm --no-deps -T \
      --entrypoint bash optimize \
      //optimize/upgrade/upgrade.sh --skip-warning; then
    echo "WARN: Optimize schema pre-flight failed. Continuing with stack start." >&2
    echo "      If optimize does not come up, run: bash scripts/optimize-upgrade.sh" >&2
  fi
fi

echo "Starting Camunda stack with STAGE=$stage"
"${COMPOSE_BASE[@]}" up -d
