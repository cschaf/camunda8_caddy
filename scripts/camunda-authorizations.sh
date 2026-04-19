#!/bin/bash
#
# SYNOPSIS
#     Applies custom Camunda authorization permissions after stack startup.
#
# DESCRIPTION
#     Patches built-in Camunda roles via the REST API to match the desired
#     permission model for this environment.
#
#     Currently applies:
#       - readonly-admin: adds UPDATE_USER_TASK on PROCESS_DEFINITION
#         so NormalUser accounts can complete tasks in Tasklist.
#
#     Safe to re-run — uses PUT (idempotent).
#
# EXAMPLES
#     bash scripts/camunda-authorizations.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

read_env() {
    local key="$1"
    grep -E "^${key}=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]'
}

CAMUNDA_HOST=$(read_env HOST)
ORCH_SECRET=$(read_env ORCHESTRATION_CLIENT_SECRET)
KEYCLOAK_HOST="keycloak.${CAMUNDA_HOST}"
ORCH_HOST="orchestration.${CAMUNDA_HOST}"

[[ -z "$CAMUNDA_HOST" ]] && echo "ERROR: HOST not found in .env" && exit 1

echo "Getting orchestration token..."
TOKEN=$(curl -sk "https://${KEYCLOAK_HOST}/auth/realms/camunda-platform/protocol/openid-connect/token" \
  -d "grant_type=client_credentials&client_id=orchestration&client_secret=${ORCH_SECRET}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

auth_header="Authorization: Bearer $TOKEN"

get_auth_key() {
    local owner_id="$1" resource_type="$2"
    curl -sk -X POST "https://${ORCH_HOST}/v2/authorizations/search" \
      -H "$auth_header" -H "Content-Type: application/json" \
      -d "{\"filter\":{\"ownerId\":\"${owner_id}\",\"resourceType\":\"${resource_type}\"}}" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['items'][0]['authorizationKey'])"
}

set_permissions() {
    local auth_key="$1" owner_id="$2" owner_type="$3" resource_type="$4" resource_id="$5"
    shift 5
    local perms_json
    perms_json=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "$@")
    curl -sk -X PUT "https://${ORCH_HOST}/v2/authorizations/${auth_key}" \
      -H "$auth_header" -H "Content-Type: application/json" \
      -d "{\"ownerId\":\"${owner_id}\",\"ownerType\":\"${owner_type}\",\"resourceType\":\"${resource_type}\",\"resourceId\":\"${resource_id}\",\"permissionTypes\":${perms_json}}" \
      -o /dev/null -w "  Updated: ${owner_id} / ${resource_type} -> %{http_code}\n"
}

echo "Applying Camunda authorization patches..."

# readonly-admin: NormalUser needs UPDATE_USER_TASK to complete tasks in Tasklist
KEY=$(get_auth_key "readonly-admin" "PROCESS_DEFINITION")
set_permissions "$KEY" "readonly-admin" "ROLE" "PROCESS_DEFINITION" "*" \
    "READ_PROCESS_INSTANCE" "READ_PROCESS_DEFINITION" "READ_USER_TASK" "UPDATE_USER_TASK"

echo ""
echo "Done!"
