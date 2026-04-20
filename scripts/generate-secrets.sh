#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
ENV_EXAMPLE="$SCRIPT_DIR/../.env.example"

FORCE=false
for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE=true
done

if [[ -f "$ENV_FILE" && "$FORCE" == false ]]; then
  echo "ERROR: .env already exists. Use --force to overwrite." >&2
  exit 1
fi

if ! command -v openssl &>/dev/null; then
  echo "ERROR: openssl is required but not found." >&2
  exit 1
fi

gen() {
  openssl rand -hex 24
}

get_val() {
  grep "^$1=" "$ENV_EXAMPLE" | head -1 | cut -d= -f2-
}

cat > "$ENV_FILE" <<EOF
## Image versions ##
$(grep '^# renovate:' "$ENV_EXAMPLE" | head -1 || true)
CAMUNDA_VERSION=$(get_val CAMUNDA_VERSION)
CAMUNDA_CONNECTORS_VERSION=$(get_val CAMUNDA_CONNECTORS_VERSION)
CAMUNDA_IDENTITY_VERSION=$(get_val CAMUNDA_IDENTITY_VERSION)
CAMUNDA_OPERATE_VERSION=$(get_val CAMUNDA_OPERATE_VERSION)
CAMUNDA_OPTIMIZE_VERSION=$(get_val CAMUNDA_OPTIMIZE_VERSION)
CAMUNDA_TASKLIST_VERSION=$(get_val CAMUNDA_TASKLIST_VERSION)
CAMUNDA_WEB_MODELER_VERSION=$(get_val CAMUNDA_WEB_MODELER_VERSION)
CAMUNDA_CONSOLE_VERSION=$(get_val CAMUNDA_CONSOLE_VERSION)
ELASTIC_VERSION=$(get_val ELASTIC_VERSION)
KEYCLOAK_SERVER_VERSION=$(get_val KEYCLOAK_SERVER_VERSION)
MAILPIT_VERSION=$(get_val MAILPIT_VERSION)
POSTGRES_VERSION=$(get_val POSTGRES_VERSION)

## Network Configuration ##
HOST=$(get_val HOST)
KEYCLOAK_HOST=$(get_val KEYCLOAK_HOST)

## Stage / Environment Label ##
STAGE=$(get_val STAGE)

## Dashboard Banner ##
BANNER_DARKMODE=$(get_val BANNER_DARKMODE)
BANNER_LIGHTMODE=$(get_val BANNER_LIGHTMODE)

## TLS Certificates (Optional) ##
FULLCHAIN_PEM=$(get_val FULLCHAIN_PEM)
PRIVATEKEY_PEM=$(get_val PRIVATEKEY_PEM)

## OIDC Client Configuration ##
ORCHESTRATION_CLIENT_ID=$(get_val ORCHESTRATION_CLIENT_ID)
ORCHESTRATION_CLIENT_SECRET=$(gen)

CONNECTORS_CLIENT_ID=$(get_val CONNECTORS_CLIENT_ID)
CONNECTORS_CLIENT_SECRET=$(gen)

CONSOLE_CLIENT_SECRET=$(gen)

OPTIMIZE_CLIENT_SECRET=$(gen)

CAMUNDA_IDENTITY_CLIENT_SECRET=$(gen)

## Database Configuration ##
POSTGRES_DB=$(get_val POSTGRES_DB)
POSTGRES_USER=$(get_val POSTGRES_USER)
POSTGRES_PASSWORD=$(gen)

WEBMODELER_DB_NAME=$(get_val WEBMODELER_DB_NAME)
WEBMODELER_DB_USER=$(get_val WEBMODELER_DB_USER)
WEBMODELER_DB_PASSWORD=$(gen)

## Keycloak Admin Credentials ##
KEYCLOAK_ADMIN_USER=$(get_val KEYCLOAK_ADMIN_USER)
KEYCLOAK_ADMIN_PASSWORD=$(gen)

## Web Modeler Configuration ##
WEBMODELER_PUSHER_APP_ID=$(get_val WEBMODELER_PUSHER_APP_ID)
WEBMODELER_PUSHER_KEY=$(gen)
WEBMODELER_PUSHER_SECRET=$(gen)

WEBMODELER_MAIL_FROM_ADDRESS=$(get_val WEBMODELER_MAIL_FROM_ADDRESS)

## Demo User ##
DEMO_USER_PASSWORD=$(gen)

## Feature Flags ##
RESOURCE_AUTHORIZATIONS_ENABLED=$(get_val RESOURCE_AUTHORIZATIONS_ENABLED)
EOF

chmod 600 "$ENV_FILE"

echo "Generated .env with strong random secrets (chmod 600)."
echo ""
echo "Generated secrets for:"
echo "  ORCHESTRATION_CLIENT_SECRET, CONNECTORS_CLIENT_SECRET, CONSOLE_CLIENT_SECRET"
echo "  OPTIMIZE_CLIENT_SECRET, CAMUNDA_IDENTITY_CLIENT_SECRET"
echo "  POSTGRES_PASSWORD, WEBMODELER_DB_PASSWORD"
echo "  KEYCLOAK_ADMIN_PASSWORD, WEBMODELER_PUSHER_KEY, WEBMODELER_PUSHER_SECRET"
echo "  DEMO_USER_PASSWORD"
echo ""
echo "Edit HOST in .env before starting the stack if needed."
