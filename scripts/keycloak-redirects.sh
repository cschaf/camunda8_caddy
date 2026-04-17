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
# Helper functions (Python for reliable JSON handling)
# ---------------------------------------------------------------------------

python_escape_uri() {
    python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$1"
}

get_admin_token() {
    local token_url="https://${KEYCLOAK_HOST}/auth/realms/master/protocol/openid-connect/token"
    local token_body="grant_type=password&username=${ADMIN_USER}&password=${ADMIN_PASSWORD}&client_id=admin-cli"

    local access_token
    access_token=$(curl -s -k -X POST "$token_url" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "$token_body" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('access_token', ''))
except:
    print('')
")

    if [[ -z "$access_token" ]]; then
        echo "ERROR: Failed to get admin token. Check KEYCLOAK_HOST and admin credentials." >&2
        exit 1
    fi

    echo "$access_token"
}

update_client_redirect_uris() {
    local client_id="$1"
    local localhost_uri="$2"
    local proxy_uri="$3"
    local bearer_token="$4"

    # Use Python to fetch client, extract data, and update via Keycloak API
    python3 << EOF
import json
import sys
import subprocess
import urllib.request
import urllib.parse

KEYCLOAK_HOST = "$KEYCLOAK_HOST"
REALM = "$REALM"
CLIENT_ID = "$client_id"
LOCALHOST_URI = "$localhost_uri"
PROXY_URI = "$proxy_uri"
BEARER_TOKEN = "$bearer_token"

def api_get(path):
    url = f"https://{KEYCLOAK_HOST}/auth/admin/realms/{REALM}/{path}"
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {BEARER_TOKEN}")
    req.add_header("Accept", "application/json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())

def api_put(path, data):
    url = f"https://{KEYCLOAK_HOST}/auth/admin/realms/{REALM}/{path}"
    req = urllib.request.Request(url, data=json.dumps(data).encode(), method="PUT")
    req.add_header("Authorization", f"Bearer {BEARER_TOKEN}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status in (200, 204):
                return {}
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode() if e.fp else ""
        raise Exception(f"HTTP {e.code}: {err_body}")

# Find client
clients = api_get(f"clients?clientId={CLIENT_ID}")
if not clients:
    print(f"  Client '{CLIENT_ID}' not found, skipping...")
    sys.exit(0)

client = clients[0]
client_uuid = client["id"]
print(f"  Found client with id: {client_uuid}")

# Get current client details
current = api_get(f"clients/{client_uuid}")

# Current URIs
current_uris = current.get("redirectUris", [])
print("  Current redirect URIs:")
for u in current_uris:
    print(f"    {u}")

# Build new URIs (deduplicated)
all_uris = list(set(current_uris + [LOCALHOST_URI, PROXY_URI]))
print("  New redirect URIs:")
for u in all_uris:
    print(f"    {u}")

# Update client - remove rootUrl to avoid "Resource does not allow updating" errors
updated = {k: v for k, v in current.items() if k != "rootUrl"}
updated["redirectUris"] = all_uris

try:
    api_put(f"clients/{client_uuid}", updated)
    print("  Updated!")
except Exception as e:
    print(f"  ERROR updating client: {e}")
EOF
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