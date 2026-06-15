#!/usr/bin/env bash
set -euo pipefail

# Generates .env-credentials with strong random secrets.
# Reads non-credential defaults (HOST, STAGE, *_CLIENT_ID, etc.) from the
# committed .env so the generated file matches the active configuration.
# .env is NOT modified by this script — it is part of the repo and is
# expected to already exist when generate-secrets is run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
CREDENTIALS_FILE="$SCRIPT_DIR/../.env-credentials"

FORCE=false
for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE=true
done

if [[ -f "$CREDENTIALS_FILE" && "$FORCE" == false ]]; then
  echo "ERROR: .env-credentials already exists. Use --force to overwrite." >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found. It is part of the repo, so this should not happen." >&2
  echo "       Re-clone the repository, or restore .env from your last commit." >&2
  exit 1
fi

if ! command -v openssl &>/dev/null; then
  echo "ERROR: openssl is required but not found." >&2
  exit 1
fi

gen() {
  openssl rand -hex 24
}

# Read a single KEY=VALUE line from .env (non-credential source). Skips
# comments and blank lines. Returns the empty string if not found.
get_val() {
  grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-
}

default_val() {
  case "$1" in
    ORCHESTRATION_CLIENT_ID) printf '%s' 'orchestration' ;;
    CONNECTORS_CLIENT_ID) printf '%s' 'connectors' ;;
    POSTGRES_DB) printf '%s' 'bitnami_keycloak' ;;
    POSTGRES_USER) printf '%s' 'bn_keycloak' ;;
    CAMUNDA_DB_NAME) printf '%s' 'camunda' ;;
    CAMUNDA_DB_USER) printf '%s' 'camunda' ;;
    WEBMODELER_DB_NAME) printf '%s' 'web-modeler-db' ;;
    WEBMODELER_DB_USER) printf '%s' 'web-modeler-db-user' ;;
    KEYCLOAK_ADMIN_USER) printf '%s' 'admin' ;;
    WEBMODELER_PUSHER_APP_ID) printf '%s' 'web-modeler-app' ;;
    *) printf '%s' '' ;;
  esac
}

get_val_or_default() {
  local key="$1"
  local value
  value="$(get_val "$key")"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    default_val "$key"
  fi
}

# Pre-generate secrets that are written to .env-credentials
ELASTIC_PASSWORD=$(gen)
POSTGRES_PASSWORD=$(gen)
CAMUNDA_DB_PASSWORD=$(gen)
WEBMODELER_DB_PASSWORD=$(gen)
KEYCLOAK_ADMIN_PASSWORD=$(gen)
WEBMODELER_PUSHER_KEY=$(gen)
WEBMODELER_PUSHER_SECRET=$(gen)
DEMO_USER_PASSWORD=$(gen)

cat > "$CREDENTIALS_FILE" <<EOF
## Camunda Private Registry (Optional) ##
# Used by scripts/registry-info.{ps1,sh} to query Camunda's Harbor registry.
# Credentials are issued by Camunda to enterprise customers (robot accounts).
CAMUNDA_REGISTRY_USERNAME=$(get_val CAMUNDA_REGISTRY_USERNAME)
CAMUNDA_REGISTRY_PASSWORD=$(gen)

## OIDC Client Configuration ##
ORCHESTRATION_CLIENT_ID=$(get_val_or_default ORCHESTRATION_CLIENT_ID)
ORCHESTRATION_CLIENT_SECRET=$(gen)

CONNECTORS_CLIENT_ID=$(get_val_or_default CONNECTORS_CLIENT_ID)
CONNECTORS_CLIENT_SECRET=$(gen)

CONSOLE_CLIENT_SECRET=$(gen)

OPTIMIZE_CLIENT_SECRET=$(gen)

CAMUNDA_IDENTITY_CLIENT_SECRET=$(gen)

## Elasticsearch Configuration ##
ELASTIC_PASSWORD=$ELASTIC_PASSWORD

## Database Configuration ##
POSTGRES_DB=$(get_val_or_default POSTGRES_DB)
POSTGRES_USER=$(get_val_or_default POSTGRES_USER)
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

CAMUNDA_DB_NAME=$(get_val_or_default CAMUNDA_DB_NAME)
CAMUNDA_DB_USER=$(get_val_or_default CAMUNDA_DB_USER)
CAMUNDA_DB_PASSWORD=$CAMUNDA_DB_PASSWORD

WEBMODELER_DB_NAME=$(get_val_or_default WEBMODELER_DB_NAME)
WEBMODELER_DB_USER=$(get_val_or_default WEBMODELER_DB_USER)
WEBMODELER_DB_PASSWORD=$WEBMODELER_DB_PASSWORD

## Keycloak Admin Credentials ##
KEYCLOAK_ADMIN_USER=$(get_val_or_default KEYCLOAK_ADMIN_USER)
KEYCLOAK_ADMIN_PASSWORD=$KEYCLOAK_ADMIN_PASSWORD

## Web Modeler Configuration ##
WEBMODELER_PUSHER_APP_ID=$(get_val_or_default WEBMODELER_PUSHER_APP_ID)
WEBMODELER_PUSHER_KEY=$WEBMODELER_PUSHER_KEY
WEBMODELER_PUSHER_SECRET=$WEBMODELER_PUSHER_SECRET

## Camunda License (Optional for non-production, required for production use) ##
# Keep the real key only in .env-credentials. For multi-line keys, use
# single quotes so docker compose and the bash start script keep the value
# as one variable.
# CAMUNDA_LICENSE_KEY='--------------- BEGIN CAMUNDA LICENSE KEY ---------------
# ... complete key from Camunda ...
# --------------- END CAMUNDA LICENSE KEY ---------------'

## Demo User ##
DEMO_USER_PASSWORD=$DEMO_USER_PASSWORD
EOF

chmod 600 "$CREDENTIALS_FILE"

echo "Generated .env-credentials with strong random secrets (chmod 600)."
echo ""
echo "Generated secrets for:"
echo "  ORCHESTRATION_CLIENT_SECRET, CONNECTORS_CLIENT_SECRET, CONSOLE_CLIENT_SECRET"
echo "  OPTIMIZE_CLIENT_SECRET, CAMUNDA_IDENTITY_CLIENT_SECRET"
echo "  ELASTIC_PASSWORD"
echo "  POSTGRES_PASSWORD, WEBMODELER_DB_PASSWORD, CAMUNDA_DB_PASSWORD"
echo "  KEYCLOAK_ADMIN_PASSWORD, WEBMODELER_PUSHER_KEY, WEBMODELER_PUSHER_SECRET"
echo "  DEMO_USER_PASSWORD"
echo ""
echo "Edit HOST in .env before starting the stack if needed."
