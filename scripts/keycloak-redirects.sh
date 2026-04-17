#!/bin/bash
#
# SYNOPSIS
#     Configures Keycloak OIDC client redirect URIs for the Caddy reverse proxy.
#
# DESCRIPTION
#     After a fresh `docker compose up`, Keycloak is initialized with redirect URIs
#     pointing to localhost (e.g. http://localhost:8088). This script replaces those
#     with the correct HTTPS proxy URLs so that all services work when accessed via
#     https://*.localhost behind Caddy.
#
#     Keycloak caches redirect URIs strictly  -  if a browser gets redirected to a URI
#     that is not in the client's allowed list, you get "Invalid redirect_uri" and the
#     login fails.
#
#     Run this ONCE after the first `docker compose up` of a fresh environment.
#     It is safe to re-run.
#
#     Prerequisites:
#     - Caddy reverse proxy must be running so keycloak.localhost resolves
#     - Admin credentials default to admin/admin
#
# EXAMPLES
#     bash scripts/keycloak-redirects.sh
#
#     # Run against a different Keycloak host
#     bash scripts/keycloak-redirects.sh --keycloak-host keycloak.staging.example.com
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

# Default configuration (KEYCLOAK_HOST resolved after reading .env HOST below)
REALM="${REALM:-camunda-platform}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

usage() {
    echo "Usage: $0 [--keycloak-host <host>] [--realm <realm>] [--admin-user <user>] [--admin-password <pass>]"
    echo ""
    echo "Options:"
    echo "  --keycloak-host <host>  Keycloak host (default: keycloak.localhost)"
    echo "  --realm <realm>          Keycloak realm (default: camunda-platform)"
    echo "  --admin-user <user>      Admin username (default: admin)"
    echo "  --admin-password <pass> Admin password (default: admin)"
    echo ""
    echo "Environment variables:"
    echo "  KEYCLOAK_HOST, REALM, ADMIN_USER, ADMIN_PASSWORD"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keycloak-host)
            KEYCLOAK_HOST="$2"
            shift 2
            ;;
        --realm)
            REALM="$2"
            shift 2
            ;;
        --admin-user)
            ADMIN_USER="$2"
            shift 2
            ;;
        --admin-password)
            ADMIN_PASSWORD="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Read HOST from .env
# ---------------------------------------------------------------------------

PROXY_DOMAIN=""
if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^HOST=(.*) ]]; then
            PROXY_DOMAIN="${BASH_REMATCH[1]}"
            PROXY_DOMAIN="${PROXY_DOMAIN//[[:space:]]/}"
        fi
    done < "$ENV_FILE"
fi

# If no HOST in .env, default to localhost
LOCAL_HOST="${PROXY_DOMAIN:-localhost}"

# Default KEYCLOAK_HOST to keycloak.{HOST} unless overridden via env var or --keycloak-host flag
KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.${LOCAL_HOST}}"

# Per-service port mapping: "client-id" = port for direct localhost access
declare -A LOCAL_PORTS=(
    ["camunda-identity"]="8084"
    ["console"]="8087"
    ["orchestration"]="8088"
    ["optimize"]="8083"
    ["web-modeler"]="8070"
)

# Per-service subdomain prefix for proxy URLs (appplied to PROXY_DOMAIN)
declare -A PROXY_SUBDOMAINS=(
    ["camunda-identity"]="identity"
    ["console"]="console"
    ["orchestration"]="orchestration"
    ["optimize"]="optimize"
    ["web-modeler"]="webmodeler"
)

# Per-service callback path after the base URL
declare -A CALLBACK_PATHS=(
    ["camunda-identity"]="/auth/login-callback"
    ["console"]="/"
    ["orchestration"]="/sso-callback"
    ["optimize"]="/api/authentication/callback"
    ["web-modeler"]="/login-callback"
)

ALL_CLIENTS="${!LOCAL_PORTS[@]}"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

get_admin_token() {
    local token_url="https://${KEYCLOAK_HOST}/auth/realms/master/protocol/openid-connect/token"
    local token_body="grant_type=password&username=${ADMIN_USER}&password=${ADMIN_PASSWORD}&client_id=admin-cli"

    echo "Getting admin token from Keycloak..."

    local response
    response=$(curl -s -k -X POST "$token_url" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "$token_body")

    local access_token
    access_token=$(echo "$response" | grep -o '"access_token"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')

    if [[ -z "$access_token" ]]; then
        echo "ERROR: Failed to get admin token. Check KEYCLOAK_HOST and admin credentials."
        echo "Response: $response"
        exit 1
    fi

    echo "$access_token"
}

update_client_redirect_uris() {
    local client_id="$1"
    local localhost_uri="$2"
    local proxy_uri="$3"
    local bearer_token="$4"
    local new_uris=("$localhost_uri" "$proxy_uri")

    local clients_url="https://${KEYCLOAK_HOST}/auth/admin/realms/${REALM}/clients?clientId=${client_id}"

    local clients_response
    clients_response=$(curl -s -k -X GET "$clients_url" \
        -H "Authorization: Bearer ${bearer_token}" \
        -H "Accept: application/json")

    # Check if client was found
    if [[ "$clients_response" == "[]" ]] || [[ -z "$clients_response" ]]; then
        echo "  Client '$client_id' not found, skipping..."
        return
    fi

    # Extract client ID (first match)
    local client_uuid
    client_uuid=$(echo "$clients_response" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"/\1/')

    if [[ -z "$client_uuid" ]]; then
        echo "  Client '$client_id' not found, skipping..."
        return
    fi

    echo "  Found client with id: $client_uuid"

    local client_url="https://${KEYCLOAK_HOST}/auth/admin/realms/${REALM}/clients/${client_uuid}"
    local current_client
    current_client=$(curl -s -k -X GET "$client_url" \
        -H "Authorization: Bearer ${bearer_token}" \
        -H "Accept: application/json")

    # Extract current redirect URIs
    local current_uris
    current_uris=$(echo "$current_client" | grep -o '"redirectUris"[[:space:]]*:[[:space:]]*\[[^]]*\]' | sed 's/"redirectUris"[[:space:]]*:[[:space:]]*//')

    echo "  Current redirect URIs:"
    echo "$current_uris" | grep -o '"[^"]*"' | while read -r uri; do
        echo "    $uri"
    done

    # Build new URIs list (current + new, deduplicated)
    local all_uris="$current_uris"
    for uri in "${new_uris[@]}"; do
        # Check if URI already exists in current list
        if ! echo "$current_uris" | grep -q "\"$uri\""; then
            all_uris="${all_uris%,]},\"${uri}\"]"
        fi
    done

    echo "  New redirect URIs:"
    echo "$all_uris" | grep -o '"[^"]*"' | while read -r uri; do
        echo "    $uri"
    done

    # Update client - remove rootUrl to avoid "Resource does not allow updating" errors
    local updated_client
    updated_client=$(echo "$current_client" | sed 's/"rootUrl"[[:space:]]*:[[:space:]]*"[^"]*",[[:space:]]*//')
    updated_client=$(echo "$updated_client" | sed 's/"redirectUris"[[:space:]]*:[[:space:]]*\[[^]]*\]/"redirectUris":'"$all_uris"'/')

    local update_response
    update_response=$(curl -s -k -X PUT "$client_url" \
        -H "Authorization: Bearer ${bearer_token}" \
        -H "Content-Type: application/json" \
        -d "$updated_client")

    # Check for errors in response
    if echo "$update_response" | grep -qi '"error"'; then
        echo "  ERROR updating client: $update_response"
    else
        echo "  Updated!"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

access_token=$(get_admin_token)

echo ""
echo "Configuring Caddy proxy redirect URIs for Keycloak clients"
echo ""

for client_id in "${!LOCAL_PORTS[@]}"; do
    echo "Updating client: $client_id..."

    port="${LOCAL_PORTS[$client_id]}"
    subdomain="${PROXY_SUBDOMAINS[$client_id]}"
    callback_path="${CALLBACK_PATHS[$client_id]}"

    localhost_uri="http://${LOCAL_HOST}:${port}${callback_path}"
    proxy_uri="https://${subdomain}.${PROXY_DOMAIN:-localhost}${callback_path}"

    echo "  localhost_uri: $localhost_uri"
    echo "  proxy_uri: $proxy_uri"

    update_client_redirect_uris "$client_id" "$localhost_uri" "$proxy_uri" "$access_token"

    echo ""
done

echo "Done!"
