#!/usr/bin/env bash
# Run Camunda Optimize's schema upgrade against the existing Elasticsearch
# data. Required after a patch upgrade of Optimize (e.g. 8.9.1 -> 8.9.6) when
# the stored schema version in ES no longer matches the new binary.
#
# Optimize refuses to start when the version in ES is older than the binary,
# so the regular `optimize` service restart-loops with:
#   "The database Optimize schema version [X] doesn't match the current
#    Optimize version [Y]. Please make sure to run the Upgrade first."
#
# This script:
#   1. Stops the broken `optimize` service (the running container is in a
#      restart-loop and would block the upgrade from being needed).
#   2. Runs the bundled upgrade one-shot in a transient container that
#      inherits the service's env config and joins the same network so it can
#      reach Elasticsearch.
#   3. Restarts the regular `optimize` service and waits for it to be
#      healthy.
#
# The upgrade is non-destructive: ES metadata is updated in place, no indices
# are dropped, no Optimize data is lost. It is safe to re-run idempotently
# (each step logs "no update to perform" if already at the target version).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

# Disable Git Bash on Windows path translation. The Optimize upgrade script
# lives at /optimize/upgrade/upgrade.sh inside the container; the leading
# double-slash tells MSYS to leave the path alone. On Linux/macOS the env
# var and the double-slash are harmless no-ops.
export MSYS_NO_PATHCONV=1

# Show what is about to happen.
echo ">> Stopping the (currently broken) optimize service..."
docker compose stop optimize

echo
echo ">> Running Camunda Optimize schema upgrade one-shot..."
echo "   This is safe to interrupt: the upgrade is a single ES metadata"
echo "   write, but the in-flight restart loop is already broken."
echo

# --no-deps  : don't start dependencies (we just stopped optimize, and ES
#              is already running).
# --rm       : remove the one-shot container when it exits.
# -T         : disable pseudo-TTY so output is plain log lines.
# The //optimize/upgrade/upgrade.sh path is the container-internal Linux
# path; the leading double-slash is the Git Bash MSYS path translation
# workaround documented above.
docker compose run --rm --no-deps -T \
  --entrypoint bash \
  optimize \
  //optimize/upgrade/upgrade.sh --skip-warning

echo
echo ">> Upgrade finished. Starting the regular optimize service..."
docker compose up -d optimize

echo
echo ">> Waiting for optimize to become healthy (timeout 120s)..."
ATTEMPTS=0
MAX_ATTEMPTS=24
until [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; do
  STATUS=$(docker compose ps --format '{{.Status}}' optimize 2>/dev/null || true)
  if echo "$STATUS" | grep -q "(healthy)"; then
    echo "   optimize is healthy: $STATUS"
    exit 0
  fi
  if echo "$STATUS" | grep -qi "exited\|dead\|restarting"; then
    echo "   optimize is NOT healthy: $STATUS"
    echo "   Run: docker compose logs --tail=100 optimize"
    exit 1
  fi
  ATTEMPTS=$((ATTEMPTS + 1))
  sleep 5
done

echo "   Timed out waiting for optimize to become healthy."
echo "   Run: docker compose logs --tail=100 optimize"
exit 1
