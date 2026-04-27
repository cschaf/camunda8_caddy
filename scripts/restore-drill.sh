#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/drill-common.sh"

usage() {
  echo "Usage: $(basename "$0") [OPTIONS] [backup-directory]"
  echo ""
  echo "Arguments:"
  echo "  backup-directory   Path to backup directory (default: most recent under backups/)"
  echo ""
  echo "Options:"
  echo "  --keep            Keep the drill stack running after completion or failure"
  echo "  -h, --help        Show this help message"
  echo ""
  echo "Environment:"
  echo "  DRILL_PORT_OFFSET       Port offset for drill stack (default: 10000)"
  echo "  DRILL_HOST              Hostname for drill stack (default: drill.localhost)"
  echo "  DRILL_PROJECT_NAME      Compose project name (default: camunda-restoredrill)"
  echo "  DRILL_KNOWN_PROJECT_ID  Optional project ID for smoke-test API check"
  exit 0
}

KEEP=false
BACKUP_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      KEEP=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="$1"
      else
        echo "Unexpected argument: $1"
        usage
      fi
      shift
      ;;
  esac
done

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
  if [[ "$KEEP" == true ]]; then
    log_drill "Keeping drill stack running for manual inspection (port offset: ${DRILL_PORT_OFFSET})"
    log_drill "Teardown later with: docker compose -p ${DRILL_PROJECT_NAME} down --volumes --remove-orphans"
  else
    teardown_drill_stack
  fi
  exit $exit_code
}
trap cleanup EXIT

generate_drill_env
run_drill_stack_up "$BACKUP_DIR"
run_smoke_tests
log_drill "Restore drill completed successfully."
