#!/usr/bin/env python3
"""
Init script for the camunda-init Docker Compose service.
Patches Camunda authorization roles after stack startup.
Uses only Python stdlib — no pip dependencies required.
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request

KEYCLOAK   = "http://keycloak:18080"
ORCH       = "http://orchestration:8080"
SECRET     = os.environ["ORCHESTRATION_CLIENT_SECRET"]
MAX_TRIES  = 20
RETRY_WAIT = 6  # seconds


def http(method, url, data=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise RuntimeError("HTTP %d: %s" % (e.code, e.read().decode()))


def get_token():
    payload = urllib.parse.urlencode({
        "grant_type":    "client_credentials",
        "client_id":     "orchestration",
        "client_secret": SECRET,
    }).encode()
    req = urllib.request.Request(
        KEYCLOAK + "/auth/realms/camunda-platform/protocol/openid-connect/token",
        data=payload,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())["access_token"]


def wait_for_token():
    for attempt in range(1, MAX_TRIES + 1):
        try:
            return get_token()
        except Exception as exc:
            print(f"[{attempt}/{MAX_TRIES}] Orchestration not ready yet: {exc}", flush=True)
            if attempt == MAX_TRIES:
                sys.exit("ERROR: orchestration never became ready")
            time.sleep(RETRY_WAIT)


# ---------------------------------------------------------------------------
# Patches to apply
# ---------------------------------------------------------------------------
PATCHES = [
    {
        "description": "readonly-admin: add UPDATE_USER_TASK so NormalUser can complete tasks in Tasklist",
        "filter":      {"ownerId": "readonly-admin", "resourceType": "PROCESS_DEFINITION"},
        "update": {
            "ownerId":         "readonly-admin",
            "ownerType":       "ROLE",
            "resourceType":    "PROCESS_DEFINITION",
            "resourceId":      "*",
            "permissionTypes": [
                "READ_PROCESS_INSTANCE",
                "READ_PROCESS_DEFINITION",
                "READ_USER_TASK",
                "UPDATE_USER_TASK",
            ],
        },
    },
]


def apply_patches(token):
    for patch in PATCHES:
        print(f"  Applying: {patch['description']}", flush=True)
        result = http("POST", ORCH + "/v2/authorizations/search", {"filter": patch["filter"]}, token)
        items = result.get("items", [])
        if not items:
            print(f"  WARN: no authorization found for filter {patch['filter']}, skipping", flush=True)
            continue
        auth_key = items[0]["authorizationKey"]
        http("PUT", ORCH + f"/v2/authorizations/{auth_key}", patch["update"], token)
        print(f"  OK (authorizationKey={auth_key})", flush=True)


if __name__ == "__main__":
    print("camunda-init: waiting for orchestration...", flush=True)
    token = wait_for_token()
    print("camunda-init: applying authorization patches...", flush=True)
    apply_patches(token)
    print("camunda-init: done.", flush=True)
