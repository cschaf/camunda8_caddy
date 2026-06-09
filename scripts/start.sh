#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env file not found. Run: cp .env.example .env" >&2
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
    envsubst '$HOST $DISPLAY_STAGE' < "$CONSOLE_TEMPLATE" > "$CONSOLE_CONFIG"
  else
    sed "s/\\\${HOST}/$HOST/g; s/\\\${DISPLAY_STAGE}/$display_stage/g" "$CONSOLE_TEMPLATE" > "$CONSOLE_CONFIG"
  fi
fi

# Render optimize config from template
OPTIMIZE_TEMPLATE="$PROJECT_DIR/.optimize/environment-config.yaml.example"
OPTIMIZE_CONFIG="$PROJECT_DIR/.optimize/environment-config.yaml"
if [[ -f "$OPTIMIZE_TEMPLATE" ]]; then
  sed "s/ELASTIC_PASSWORD_PLACEHOLDER/$ELASTIC_PASSWORD/g" "$OPTIMIZE_TEMPLATE" > "$OPTIMIZE_CONFIG"
fi

# Pre-flight: run the Optimize schema upgrade one-shot before starting the
# stack. Optimize persists its schema version in Elasticsearch and refuses to
# start when the stored version is older than its own binary. The upgrade is
# non-destructive and idempotent (it logs "no update to perform" if the stored
# version is already at or above the new binary), so running it on every
# start is safe. If it fails for any reason (e.g. ES not yet up), log a
# warning and continue — the regular start will surface the schema mismatch
# in the optimize container logs, and the operator can run
# `scripts/optimize-upgrade.sh` manually to recover.
#
# The `//optimize/...` leading double-slash is the Git Bash on Windows MSYS
# path translation workaround so the path is not rewritten to a Windows path
# before being passed into the container.
echo ">> Pre-flight: Optimize schema check (idempotent)..."
if ! docker compose -f "$PROJECT_DIR/docker-compose.yaml" -f "$PROJECT_DIR/stages/${stage}.yaml" \
    run --rm --no-deps -T \
    --entrypoint bash optimize \
    //optimize/upgrade/upgrade.sh --skip-warning; then
  echo "WARN: Optimize schema pre-flight failed. Continuing with stack start." >&2
  echo "      If optimize does not come up, run: bash scripts/optimize-upgrade.sh" >&2
fi

echo "Starting Camunda stack with STAGE=$stage"
docker compose -f "$PROJECT_DIR/docker-compose.yaml" -f "$PROJECT_DIR/stages/${stage}.yaml" up -d
