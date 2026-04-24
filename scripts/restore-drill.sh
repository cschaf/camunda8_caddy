#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/drill-common.sh"

usage() {
  echo "Usage: $(basename "$0") [backup-directory]"
  echo ""
  echo "Arguments:"
  echo "  backup-directory   Path to backup directory (default: most recent under backups/)"
  echo ""
  echo "Environment:"
  echo "  DRILL_PORT_OFFSET       Port offset for drill stack (default: 10000)"
  echo "  DRILL_HOST              Hostname for drill stack (default: drill.localhost)"
  echo "  DRILL_PROJECT_NAME      Compose project name (default: camunda-restoredrill)"
  echo "  DRILL_KNOWN_PROJECT_ID  Optional project ID for smoke-test API check"
  exit 0
}

BACKUP_DIR=""

if [[ $# -gt 0 ]]; then
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
  fi
  BACKUP_DIR="$1"
fi

if [[ -z "$BACKUP_DIR" ]]; then
  if [[ -d "$PROJECT_DIR/backups" ]]; then
    BACKUP_DIR="$(find "$PROJECT_DIR/backups" -maxdepth 1 -type d | grep -E '/[0-9]{8}_[0-9]{6}$' | sort | tail -n 1 || true)"
  fi
fi

if [[ -z "$BACKUP_DIR" || ! -d "$BACKUP_DIR" ]]; then
  log_drill "ERROR: No backup directory found."
  exit 1
fi

if [[ ! "$BACKUP_DIR" = /* ]]; then
  BACKUP_DIR="$PROJECT_DIR/$BACKUP_DIR"
fi

log_drill "Backup directory: $BACKUP_DIR"

cleanup() {
  local exit_code=$?
  teardown_drill_stack
  exit $exit_code
}
trap cleanup EXIT

generate_drill_env
run_drill_stack_up "$BACKUP_DIR"
run_smoke_tests
log_drill "Restore drill completed successfully."
