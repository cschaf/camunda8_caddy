#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
CREDENTIALS_FILE="$PROJECT_DIR/.env-credentials"

# Pass both .env (committed, non-secret config) and .env-credentials (gitignored,
# secrets) so docker compose can interpolate every ${VAR} reference in
# docker-compose.yaml — including the required ones like
# ORCHESTRATION_CLIENT_SECRET. The same flag pair is used by start.sh.
docker compose \
  --env-file "$ENV_FILE" \
  --env-file "$CREDENTIALS_FILE" \
  -f "$PROJECT_DIR/docker-compose.yaml" \
  down
