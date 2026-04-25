#!/bin/bash
#
# SYNOPSIS
#     Creates a Camunda user in Keycloak with role-based permissions.
#
# DESCRIPTION
#     Creates a user via the Keycloak Admin REST API and assigns Camunda-specific
#     realm roles based on the specified role level.
#
#     Credentials are read from .env in the project root.
#
# EXAMPLES
#     bash scripts/add-camunda-user.sh --username jdoe --password "changeme" --email "jdoe@example.com" --first-name John --last-name Doe --role NormalUser
#
#     bash scripts/add-camunda-user.sh --username admin --password "adminpass" --email "admin@example.com" --first-name Admin --last-name User --role Admin
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
REALM="${REALM:-camunda-platform}"
KC_UTIL="${KC_UTIL:-/tmp/kc_util.py}"

usage() {
    echo "Usage: $0 --username <user> --password <pass> --email <email> --first-name <fname> --last-name <lname> --role <role>"
    echo ""
    echo "Options:"
    echo "  --username <user>      Username for the new user"
    echo "  --password <pass>     Password for the new user"
    echo "  --email <email>       Email address"
    echo "  --first-name <fname>  First name"
    echo "  --last-name <lname>   Last name"
    echo "  --role <role>         Role: NormalUser or Admin"
    echo ""
    echo "Environment variables:"
    echo "  ADMIN_USER, ADMIN_PASSWORD, REALM, KEYCLOAK_HOST, ORCHESTRATION_HOST, KC_UTIL"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --username) USERNAME="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --email) EMAIL="$2"; shift 2 ;;
        --first-name) FIRST_NAME="$2"; shift 2 ;;
        --last-name) LAST_NAME="$2"; shift 2 ;;
        --role) ROLE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

for var in USERNAME PASSWORD EMAIL FIRST_NAME LAST_NAME ROLE; do
    if [[ -z "${!var}" ]]; then
        echo "ERROR: --$var is required"
        usage
    fi
done

if [[ "$ROLE" != "NormalUser" && "$ROLE" != "Admin" ]]; then
    echo "ERROR: --role must be NormalUser or Admin"
    usage
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

strip_outer_quotes() {
    local value="$1"
    value="${value%$'\r'}"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "$value"
}

check_host_resolution() {
    local label="$1"
    local host="$2"

    if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
        return 0
    fi

    if command -v getent >/dev/null 2>&1; then
        getent hosts "$host" >/dev/null 2>&1 && return 0
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$host" >/dev/null 2>&1 <<'PYEND' && return 0
import socket
import sys
socket.getaddrinfo(sys.argv[1], None)
PYEND
    fi

    echo "ERROR: Cannot resolve ${label} host '$host'."
    echo ""
    echo "The add-camunda-user script calls the stack through the host/proxy URLs."
    echo "Run: bash scripts/setup-host.sh"
    echo ""
    echo "This adds the required local hosts entries for:"
    echo "  keycloak.${HOST}"
    echo "  orchestration.${HOST}"
    echo ""
    echo "If this host should be resolved by DNS instead, add the matching DNS record"
    echo "or override the script host explicitly with KEYCLOAK_HOST/ORCHESTRATION_HOST."
    exit 1
}

# ---------------------------------------------------------------------------
# Read HOST and ORCHESTRATION_CLIENT_SECRET from .env
# ---------------------------------------------------------------------------

HOST=""
ORCHESTRATION_CLIENT_SECRET=""
if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^HOST=(.*) ]]; then
            HOST="${BASH_REMATCH[1]}"
            HOST="${HOST//[[:space:]]/}"
            HOST="$(strip_outer_quotes "$HOST")"
        fi
        if [[ "$line" =~ ^ORCHESTRATION_CLIENT_SECRET=(.*) ]]; then
            ORCHESTRATION_CLIENT_SECRET="${BASH_REMATCH[1]}"
            ORCHESTRATION_CLIENT_SECRET="${ORCHESTRATION_CLIENT_SECRET//[[:space:]]/}"
            ORCHESTRATION_CLIENT_SECRET="$(strip_outer_quotes "$ORCHESTRATION_CLIENT_SECRET")"
        fi
        if [[ "$line" =~ ^KEYCLOAK_ADMIN_USER=(.*) ]]; then
            ADMIN_USER="${BASH_REMATCH[1]}"
            ADMIN_USER="${ADMIN_USER//[[:space:]]/}"
            ADMIN_USER="$(strip_outer_quotes "$ADMIN_USER")"
        fi
        if [[ "$line" =~ ^KEYCLOAK_ADMIN_PASSWORD=(.*) ]]; then
            ADMIN_PASSWORD="${BASH_REMATCH[1]}"
            ADMIN_PASSWORD="${ADMIN_PASSWORD//[[:space:]]/}"
            ADMIN_PASSWORD="$(strip_outer_quotes "$ADMIN_PASSWORD")"
        fi
    done < "$ENV_FILE"
fi

REQUESTED_KEYCLOAK_HOST="${KEYCLOAK_HOST:-}"
if [[ -z "$REQUESTED_KEYCLOAK_HOST" || "$REQUESTED_KEYCLOAK_HOST" == "keycloak" ]]; then
    if [[ "$REQUESTED_KEYCLOAK_HOST" == "keycloak" ]]; then
        echo "INFO: KEYCLOAK_HOST=keycloak is the internal Docker hostname; using keycloak.${HOST} for host-side Admin API calls."
    fi
    KEYCLOAK_HOST="keycloak.${HOST}"
else
    KEYCLOAK_HOST="$REQUESTED_KEYCLOAK_HOST"
fi
ORCHESTRATION_HOST="${ORCHESTRATION_HOST:-orchestration.${HOST}}"
[[ -z "$HOST" ]] && echo "ERROR: HOST not found in .env" && exit 1
check_host_resolution "Keycloak" "$KEYCLOAK_HOST"
check_host_resolution "Orchestration" "$ORCHESTRATION_HOST"

# ---------------------------------------------------------------------------
# Role mappings
# ---------------------------------------------------------------------------

declare -A ROLE_MAP
ROLE_MAP["NormalUser"]="Default user role,Orchestration,Optimize,Web Modeler"
ROLE_MAP["Admin"]="Web Modeler,ManagementIdentity,Default user role,Orchestration,Optimize,Web Modeler Admin,Console"

# Camunda internal role (camunda.security.authorizations.enabled=true requires explicit role assignment)
declare -A CAMUNDA_ROLE_MAP
CAMUNDA_ROLE_MAP["NormalUser"]="readonly-admin"
CAMUNDA_ROLE_MAP["Admin"]="admin"

IFS=',' read -ra ROLE_NAMES <<< "${ROLE_MAP[$ROLE]}"

# ---------------------------------------------------------------------------
# Python utility (if not already present)
# ---------------------------------------------------------------------------

if [[ ! -f "$KC_UTIL" ]]; then
    cat > "$KC_UTIL" <<'PYEOF'
#!/usr/bin/env python3
import sys, json, urllib.request, urllib.parse, ssl, os

def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    keycloak_host = os.environ.get("KC_HOST", "")
    realm = os.environ.get("KC_REALM", "camunda-platform")
    token = os.environ.get("KC_TOKEN", "")
    username = os.environ.get("KC_USERNAME", "")
    password = os.environ.get("KC_PASSWORD", "")
    email = os.environ.get("KC_EMAIL", "")
    first_name = os.environ.get("KC_FIRST", "")
    last_name = os.environ.get("KC_LAST", "")
    user_id = os.environ.get("KC_USER_ID", "")
    role_name = os.environ.get("KC_ROLE_NAME", "")
    role_json_str = os.environ.get("KC_ROLE_JSON", "")

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    def get(path):
        url = f"https://{keycloak_host}/auth/admin/realms/{realm}/{path}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
            return json.loads(r.read())

    def post(path, data):
        url = f"https://{keycloak_host}/auth/admin/realms/{realm}/{path}"
        body = json.dumps(data).encode()
        req = urllib.request.Request(url, data=body, method="POST", headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json"
        })
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
                return r.status
        except urllib.error.HTTPError as e:
            err = e.read().decode() if e.fp else str(e)
            raise Exception(f"HTTP {e.code}: {err}")

    def delete(path):
        url = f"https://{keycloak_host}/auth/admin/realms/{realm}/{path}"
        req = urllib.request.Request(url, method="DELETE", headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
            return r.status

    if action == "user_exists":
        users = get(f"users?username={urllib.parse.quote(username, safe='')}")
        print(users[0]["id"] if users else "")

    elif action == "create_user":
        print(post("users", {
            "username": username, "enabled": True, "email": email,
            "firstName": first_name, "lastName": last_name,
            "credentials": [{"type": "password", "value": password, "temporary": False}]
        }))

    elif action == "get_role":
        url = f"https://{keycloak_host}/auth/admin/realms/{realm}/roles/{urllib.parse.quote(role_name, safe='')}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
            role = json.loads(r.read())
            print(json.dumps({
                "id": str(role["id"]), "name": role["name"],
                "description": role.get("description", "") or "",
                "composite": role.get("composite", False),
                "clientRole": role.get("clientRole", False),
                "containerId": str(role.get("containerId", ""))
            }))

    elif action == "assign_role":
        url = f"https://{keycloak_host}/auth/admin/realms/{realm}/users/{user_id}/role-mappings/realm"
        body = json.dumps([json.loads(role_json_str)]).encode()
        req = urllib.request.Request(url, data=body, method="POST", headers={
            "Authorization": f"Bearer {token}", "Content-Type": "application/json"
        })
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
                print("OK")
        except urllib.error.HTTPError as e:
            err = e.read().decode() if e.fp else str(e)
            print(f"ERROR: HTTP {e.code}: {err}", file=sys.stderr)
            sys.exit(1)

    elif action == "delete_user":
        delete(f"users/{user_id}")

if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$KC_UTIL"
fi

run_py() {
    KC_HOST="$KEYCLOAK_HOST" \
    KC_REALM="$REALM" \
    KC_TOKEN="$KC_TOKEN" \
    KC_USERNAME="$1" \
    KC_PASSWORD="$PASSWORD" \
    KC_EMAIL="$EMAIL" \
    KC_FIRST="$FIRST_NAME" \
    KC_LAST="$LAST_NAME" \
    KC_USER_ID="$user_id" \
    KC_ROLE_NAME="$role_name" \
    KC_ROLE_JSON="$role_json" \
    python3 "$KC_UTIL" "$action"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "Creating user '$USERNAME' with role '$ROLE'..."

# Get admin token
get_token_py=$(mktemp)
cat > "$get_token_py" <<'PYEND'
import sys, json, urllib.request, urllib.parse, urllib.error, ssl
keycloak_host = sys.argv[1]
admin_user = sys.argv[2]
admin_password = sys.argv[3]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
url = "https://%s/auth/realms/master/protocol/openid-connect/token" % keycloak_host
data = urllib.parse.urlencode({"grant_type": "password", "username": admin_user, "password": admin_password, "client_id": "admin-cli"}).encode()
req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
def fail(message, status="", content_type="", body=""):
    print("ERROR: %s" % message, file=sys.stderr)
    if status:
        print("HTTP status: %s" % status, file=sys.stderr)
    if content_type:
        print("Content-Type: %s" % content_type, file=sys.stderr)
    preview = body[:500].replace("\r", "\\r").replace("\n", "\\n")
    print("Response body preview: %s" % (preview if preview else "(empty)"), file=sys.stderr)
    sys.exit(1)

try:
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        raw = r.read()
        text = raw.decode("utf-8", errors="replace")
        try:
            payload = json.loads(text)
        except json.JSONDecodeError:
            fail("Keycloak token endpoint returned non-JSON from %s" % url, r.status, r.headers.get("Content-Type", ""), text)
except urllib.error.HTTPError as e:
    text = e.read().decode("utf-8", errors="replace")
    fail("Keycloak token endpoint rejected the admin token request at %s" % url, e.code, e.headers.get("Content-Type", ""), text)

token = payload.get("access_token")
if not token:
    fail("Keycloak token endpoint response did not contain access_token from %s" % url, body=json.dumps(payload))
print(token)
PYEND

KC_TOKEN=$(python3 "$get_token_py" "$KEYCLOAK_HOST" "$ADMIN_USER" "$ADMIN_PASSWORD")
rm -f "$get_token_py"
echo "Got admin token"

# Check if user exists
action="user_exists"
user_id=$(KC_HOST="$KEYCLOAK_HOST" KC_REALM="$REALM" KC_TOKEN="$KC_TOKEN" KC_USERNAME="$USERNAME" python3 "$KC_UTIL" user_exists)
if [[ -n "$user_id" ]]; then
    echo "ERROR: User '$USERNAME' already exists (ID: $user_id). Use Keycloak UI to delete first."
    exit 1
fi

# Create user
action="create_user"
status=$(KC_HOST="$KEYCLOAK_HOST" KC_REALM="$REALM" KC_TOKEN="$KC_TOKEN" \
    KC_USERNAME="$USERNAME" KC_PASSWORD="$PASSWORD" \
    KC_EMAIL="$EMAIL" KC_FIRST="$FIRST_NAME" KC_LAST="$LAST_NAME" \
    python3 "$KC_UTIL" create_user)
echo "User created (status: $status)"

sleep 1

# Get user ID
action="user_exists"
user_id=$(KC_HOST="$KEYCLOAK_HOST" KC_REALM="$REALM" KC_TOKEN="$KC_TOKEN" KC_USERNAME="$USERNAME" python3 "$KC_UTIL" user_exists)
if [[ -z "$user_id" ]]; then
    echo "ERROR: User '$USERNAME' not found after creation"
    exit 1
fi
echo "User ID: $user_id"

# Assign roles one at a time
for role_name in "${ROLE_NAMES[@]}"; do
    role_name=$(echo "$role_name" | xargs)
    echo "  Assigning role: $role_name"

    action="get_role"
    role_json=$(KC_HOST="$KEYCLOAK_HOST" KC_REALM="$REALM" KC_TOKEN="$KC_TOKEN" KC_ROLE_NAME="$role_name" python3 "$KC_UTIL" get_role)
    if [[ -z "$role_json" ]] || [[ "$role_json" == ERROR* ]]; then
        echo "  ERROR: Failed to get role object for '$role_name'"
        action="delete_user"
        KC_HOST="$KEYCLOAK_HOST" KC_REALM="$REALM" KC_TOKEN="$KC_TOKEN" KC_USER_ID="$user_id" \
            python3 "$KC_UTIL" delete_user 2>/dev/null || true
        echo "Rolled back: user deleted"
        exit 1
    fi

    action="assign_role"
    result=$(KC_HOST="$KEYCLOAK_HOST" KC_REALM="$REALM" KC_TOKEN="$KC_TOKEN" KC_USER_ID="$user_id" KC_ROLE_JSON="$role_json" \
        python3 "$KC_UTIL" assign_role)
    if [[ "$result" == "OK" ]]; then
        echo "  Assigned role: $role_name"
    else
        echo "  ERROR: Failed to assign role '$role_name': $result"
        action="delete_user"
        KC_HOST="$KEYCLOAK_HOST" KC_REALM="$REALM" KC_TOKEN="$KC_TOKEN" KC_USER_ID="$user_id" \
            python3 "$KC_UTIL" delete_user 2>/dev/null || true
        echo "Rolled back: user deleted"
        exit 1
    fi
done

# Assign Camunda internal role (required because camunda.security.authorizations.enabled=true)
echo "Assigning Camunda internal authorization role..."
CAMUNDA_ROLE="${CAMUNDA_ROLE_MAP[$ROLE]}"

orch_token_py=$(mktemp)
cat > "$orch_token_py" <<'PYEND'
import sys, json, urllib.request, urllib.parse, urllib.error, ssl
keycloak_host = sys.argv[1]
client_secret = sys.argv[2]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
url = "https://%s/auth/realms/camunda-platform/protocol/openid-connect/token" % keycloak_host
data = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": "orchestration", "client_secret": client_secret}).encode()
req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
def fail(message, status="", content_type="", body=""):
    print("ERROR: %s" % message, file=sys.stderr)
    if status:
        print("HTTP status: %s" % status, file=sys.stderr)
    if content_type:
        print("Content-Type: %s" % content_type, file=sys.stderr)
    preview = body[:500].replace("\r", "\\r").replace("\n", "\\n")
    print("Response body preview: %s" % (preview if preview else "(empty)"), file=sys.stderr)
    sys.exit(1)

try:
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        raw = r.read()
        text = raw.decode("utf-8", errors="replace")
        try:
            payload = json.loads(text)
        except json.JSONDecodeError:
            fail("Keycloak token endpoint returned non-JSON from %s" % url, r.status, r.headers.get("Content-Type", ""), text)
except urllib.error.HTTPError as e:
    text = e.read().decode("utf-8", errors="replace")
    fail("Keycloak token endpoint rejected the orchestration token request at %s" % url, e.code, e.headers.get("Content-Type", ""), text)

token = payload.get("access_token")
if not token:
    fail("Keycloak token endpoint response did not contain access_token from %s" % url, body=json.dumps(payload))
print(token)
PYEND

ORCH_TOKEN=$(python3 "$orch_token_py" "$KEYCLOAK_HOST" "$ORCHESTRATION_CLIENT_SECRET") && rm -f "$orch_token_py" || { rm -f "$orch_token_py"; echo "WARNING: Could not get orchestration token. Camunda authorization role not assigned."; ORCH_TOKEN=""; }

if [[ -n "$ORCH_TOKEN" ]]; then
    assign_role_py=$(mktemp)
    cat > "$assign_role_py" <<'PYEND'
import sys, json, urllib.request, ssl
orch_host = sys.argv[1]
camunda_role = sys.argv[2]
username = sys.argv[3]
token = sys.argv[4]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
url = "https://%s/v2/roles/%s/users/%s" % (orch_host, camunda_role, username)
req = urllib.request.Request(url, method="PUT", headers={"Authorization": "Bearer %s" % token})
try:
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        print("OK")
except urllib.error.HTTPError as e:
    err = e.read().decode() if e.fp else str(e)
    print("ERROR: HTTP %s: %s" % (e.code, err), file=sys.stderr)
    sys.exit(1)
PYEND

    result=$(python3 "$assign_role_py" "$ORCHESTRATION_HOST" "$CAMUNDA_ROLE" "$USERNAME" "$ORCH_TOKEN")
    rm -f "$assign_role_py"
    if [[ "$result" == "OK" ]]; then
        echo "  Assigned Camunda role: $CAMUNDA_ROLE"
    else
        echo "  WARNING: Failed to assign Camunda role '$CAMUNDA_ROLE': $result"
        echo "  User was created in Keycloak but may not be able to access Operate/Tasklist."
    fi
fi

echo ""
echo "Done! User '$USERNAME' created with role '$ROLE'."
