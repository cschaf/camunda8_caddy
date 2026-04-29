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

# Render console config from template
CONSOLE_TEMPLATE="$PROJECT_DIR/.console/application.yaml.template"
CONSOLE_CONFIG="$PROJECT_DIR/.console/application.yaml"
if [[ -f "$CONSOLE_TEMPLATE" ]]; then
  if command -v envsubst >/dev/null 2>&1; then
    envsubst '$HOST $STAGE' < "$CONSOLE_TEMPLATE" > "$CONSOLE_CONFIG"
  else
    sed "s/\\\${HOST}/$HOST/g; s/\\\${STAGE}/$stage/g" "$CONSOLE_TEMPLATE" > "$CONSOLE_CONFIG"
  fi
fi

# Render optimize config from template
OPTIMIZE_TEMPLATE="$PROJECT_DIR/.optimize/environment-config.yaml.example"
OPTIMIZE_CONFIG="$PROJECT_DIR/.optimize/environment-config.yaml"
if [[ -f "$OPTIMIZE_TEMPLATE" ]]; then
  sed "s/ELASTIC_PASSWORD_PLACEHOLDER/$ELASTIC_PASSWORD/g" "$OPTIMIZE_TEMPLATE" > "$OPTIMIZE_CONFIG"
fi

echo "Starting Camunda stack with STAGE=$stage"
docker compose -f "$PROJECT_DIR/docker-compose.yaml" -f "$PROJECT_DIR/stages/${stage}.yaml" up -d
