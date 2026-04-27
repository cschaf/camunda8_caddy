#!/bin/bash
# Setup script for configuring the Camunda Compose NVL environment
# Run this after cloning and before first start if you want to use a different hostname

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
CADDYFILE="$PROJECT_DIR/Caddyfile"
CADDYFILE_TEMPLATE="$PROJECT_DIR/Caddyfile.example"

# Default hosts file path (Linux)
HOSTS_FILE="/etc/hosts"

usage() {
    echo "Usage: $0 [--hosts-file <path>]"
    echo ""
    echo "Options:"
    echo "  --hosts-file <path>  Path to hosts file (default: /etc/hosts)"
    echo ""
    echo "Run from the project root after 'cp .env.example .env'"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hosts-file)
            HOSTS_FILE="$2"
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

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found. Run: cp .env.example .env"
    exit 1
fi

# Read HOST and optional TLS cert paths from .env
HOST=""
FULLCHAIN_PEM=""
PRIVATEKEY_PEM=""

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^HOST=(.*) ]]; then
        HOST="${BASH_REMATCH[1]}"
        HOST="${HOST//[[:space:]]/}"  # trim whitespace
    fi
    if [[ "$line" =~ ^FULLCHAIN_PEM=(.*) ]]; then
        FULLCHAIN_PEM="${BASH_REMATCH[1]}"
        FULLCHAIN_PEM="${FULLCHAIN_PEM//[[:space:]]/}"
    fi
    if [[ "$line" =~ ^PRIVATEKEY_PEM=(.*) ]]; then
        PRIVATEKEY_PEM="${BASH_REMATCH[1]}"
        PRIVATEKEY_PEM="${PRIVATEKEY_PEM//[[:space:]]/}"
    fi
done < "$ENV_FILE"

if [[ -z "$HOST" ]]; then
    echo "ERROR: HOST not found in .env"
    exit 1
fi

USE_CUSTOM_TLS=0
if [[ -n "$FULLCHAIN_PEM" && -n "$PRIVATEKEY_PEM" ]]; then
    USE_CUSTOM_TLS=1
fi

if [[ $USE_CUSTOM_TLS -eq 1 ]]; then
    echo "Using custom TLS certificates:"
    echo "  fullchain: $FULLCHAIN_PEM"
    echo "  privatekey: $PRIVATEKEY_PEM"
else
    echo "No custom TLS certificates configured — Caddy will generate self-signed certs"
fi

echo "Configuring for HOST=$HOST"

# ---------------------------------------------------------------------------
# Update Caddyfile
# ---------------------------------------------------------------------------

if [[ ! -f "$CADDYFILE" ]]; then
    echo "ERROR: Caddyfile not found at $CADDYFILE"
    exit 1
fi

if [[ ! -f "$CADDYFILE_TEMPLATE" ]]; then
    echo "ERROR: Caddyfile template not found at $CADDYFILE_TEMPLATE"
    exit 1
fi

# Always render from the committed template. Mutating an already-rendered Caddyfile
# can leave stale hosts behind after switching domains.
cp "$CADDYFILE_TEMPLATE" "$CADDYFILE"

# Replace *.localhost with *.$HOST, and standalone localhost with $HOST
sed -i "s/\b\([a-z]\+\)\.localhost\b/\1.$HOST/g" "$CADDYFILE"
sed -i "s/^localhost\b/$HOST/" "$CADDYFILE"

# Also replace any existing non-localhost hostname (e.g., camunda.dev.local -> camunda.prd.local)
# Extract whatever hostname appears after the first non-comment, non-blank line with a site block
current_host=$(grep -v '^\s*#' "$CADDYFILE" | grep -v '^\s*$' | head -1 | sed 's/\s*{.*//')
if [[ -n "$current_host" && "$current_host" != "$HOST" ]]; then
    old_escaped="${current_host//./\\.}"
    # Replace subdomains (keycloak.oldhost -> keycloak.newhost) and bare hostname (oldhost -> newhost)
    sed -i "s/\b\([a-z]\+\)\.${old_escaped}/\1.$HOST/g" "$CADDYFILE"
    sed -i "s/\b${old_escaped}/$HOST/g" "$CADDYFILE"
fi
echo "Updated Caddyfile (replaced *.localhost -> *.$HOST)"

# Strip any existing tls directives — prevents stale directives from persisting
# when switching between custom certs and auto-generated certs.
sed -i '/^[[:space:]]*tls[[:space:]]\{1,\}[^[:space:]]\{1,\}[[:space:]]\{1,\}[^[:space:]]\{1,\}/d' "$CADDYFILE"

# Add tls directive if custom certs are provided
if [[ $USE_CUSTOM_TLS -eq 1 ]]; then
    # Insert "tls <cert> <key>" only after top-level site block opening braces.
    # Top-level blocks start at column 0 (no leading whitespace), e.g.:
    #   keycloak.example.com {
    # Nested blocks (@options, handle, reverse_proxy) are indented and must NOT get a tls line.
    # Use | as delimiter to avoid conflicts with / in file paths
    sed -i "s|^\([a-zA-Z0-9*][a-zA-Z0-9.*:-]*[[:space:]]*{[[:space:]]*\)$|\\1\n    tls $FULLCHAIN_PEM $PRIVATEKEY_PEM|" "$CADDYFILE"
    echo "Added tls directive to Caddyfile"
fi

# ---------------------------------------------------------------------------
# Update hosts file
# ---------------------------------------------------------------------------

SUBDOMAINS="keycloak identity console optimize orchestration webmodeler"
HOSTS_MARKER="# Camunda Compose NVL - $HOST"
HOSTS_BLOCK="$HOSTS_MARKER\n127.0.0.1 ${HOST}"
for subdomain in $SUBDOMAINS; do
    HOSTS_BLOCK="$HOSTS_BLOCK\n127.0.0.1 ${subdomain}.${HOST}"
done

# Check if we need sudo to write to hosts file
_write_hosts() {
    local temp_hosts
    temp_hosts="$(mktemp)"

    # Remove old Camunda entries
    grep -v '# Camunda Compose NVL' "$HOSTS_FILE" > "$temp_hosts"

    # Append new entries
    printf "%s\n" "$HOSTS_BLOCK" >> "$temp_hosts"

    if [[ "$HOSTS_FILE" == "/etc/hosts" ]]; then
        if [[ -w "$HOSTS_FILE" ]]; then
            cp "$temp_hosts" "$HOSTS_FILE"
        else
            echo "WARNING: /etc/hosts is not writable. Trying with sudo..."
            sudo cp "$temp_hosts" "$HOSTS_FILE"
        fi
    else
        cp "$temp_hosts" "$HOSTS_FILE"
    fi

    rm -f "$temp_hosts"
}

_write_hosts
echo "Updated hosts file (replaced *.localhost -> *.$HOST)"

echo ""
echo "Done! Restart Caddy or run: docker compose restart reverse-proxy"
