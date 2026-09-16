#!/usr/bin/env bash
# scripts/logs.sh — view logs of stack components without typing env-file flags
# Usage:
#   bash scripts/logs.sh <component> [component2 ...] [options]
#
# Components (container names from docker-compose.yaml):
#   reverse-proxy, orchestration, connectors, optimize, identity, keycloak,
#   postgres, camunda-db, web-modeler-db, mailpit, web-modeler-restapi,
#   web-modeler-websockets, console, elasticsearch, autoheal, camunda-data-init
#   all
#
# Options:
#   -f            follow output
#   --tail N      last N lines (default 200)
#   --since S     only logs newer than S (e.g. 15m, 2026-09-16T00:00:00)
#   -g PATTERN    filter output with grep -E --ignore-case PATTERN
#   -h, --help    show this help
#
# Examples:
#   bash scripts/logs.sh reverse-proxy
#   bash scripts/logs.sh orchestration keycloak -f
#   bash scripts/logs.sh web-modeler-restapi --since 30m -g "error"
#   bash scripts/logs.sh all --tail 50

set -uo pipefail

TAIL=200
FOLLOW=false
SINCE=""
GREP_PATTERN=""
COMPONENTS=()

usage() { grep '^#' "$0" | tail -n +2; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) FOLLOW=true; shift ;;
    --tail) TAIL="$2"; shift 2 ;;
    --tail=*) TAIL="${1#*=}"; shift ;;
    --since) SINCE="$2"; shift 2 ;;
    -g) GREP_PATTERN="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage ;;
    *) COMPONENTS+=("$1"); shift ;;
  esac
done

if [[ ${#COMPONENTS[@]} -eq 0 ]]; then
  usage
fi

ALL_NAMES='^(reverse-proxy|orchestration|connectors|optimize|identity|keycloak|postgres|camunda-db|web-modeler-db|mailpit|web-modeler-restapi|web-modeler-websockets|console|elasticsearch|autoheal|camunda-data-init)$'

declare -A SEEN=()
for c in "${COMPONENTS[@]}"; do
  if [[ -n "${SEEN[$c]:-}" ]]; then
    continue
  fi
  SEEN[$c]=1

  if [[ "$c" == "all" ]]; then
    targets=$(docker ps -a --format '{{.Names}}' | grep -E "$ALL_NAMES" || true)
    if [[ -z "$targets" ]]; then
      echo "WARN: no component containers found (is the stack running?)" >&2
    fi
  else
    if ! echo "$c" | grep -qE "$ALL_NAMES"; then
      echo "ERROR: unknown component: $c" >&2
      echo "Known components: see 'bash scripts/logs.sh --help'" >&2
      exit 2
    fi
    targets="$c"
  fi

  for container in $targets; do
    if ! docker inspect "$container" >/dev/null 2>&1; then
      echo "WARN: container '$container' not found — was it created? (stack running?)" >&2
      continue
    fi

    args=()
    $FOLLOW && args+=(-f)
    args+=(--tail "$TAIL")
    [[ -n "$SINCE" ]] && args+=(--since "$SINCE")

    if [[ -n "$GREP_PATTERN" ]]; then
      echo "===== $container (grep: $GREP_PATTERN) ====="
      docker logs "${args[@]}" "$container" 2>&1 | grep -E --ignore-case "$GREP_PATTERN" || true
    else
      echo "===== $container ====="
      docker logs "${args[@]}" "$container" 2>&1 || true
    fi
    $FOLLOW && break
  done
done
