#!/usr/bin/env bash
# scripts/logs.sh — view logs of stack components without typing env-file flags
# Usage:
#   bash scripts/logs.sh <component> [component2 ...] [options]
#
# Components (aliases allowed):
#   caddy|proxy|reverse-proxy, orchestration|zeebe, connectors, optimize,
#   identity, keycloak, postgres, camunda-db, web-modeler-db, mailpit,
#   restapi|web-modeler|modeler, websockets, console, elasticsearch|es,
#   autoheal, camunda-data-init, all
#
# Options:
#   -f            follow output
#   --tail N      last N lines (default 200)
#   --since S     only logs newer than S (e.g. 15m, 2026-09-16T00:00:00)
#   -g PATTERN    filter output with grep -E --ignore-case PATTERN
#   -h, --help    show this help
#
# Examples:
#   bash scripts/logs.sh caddy
#   bash scripts/logs.sh orchestration keycloak -f
#   bash scripts/logs.sh restapi --since 30m -g "error"
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

resolve() {
  case "$1" in
    caddy|proxy)                   echo "reverse-proxy" ;;
    reverse-proxy|orchestration|connectors|optimize|identity|keycloak|mailpit|console|autoheal|camunda-data-init)
                                   echo "$1" ;;
    orchestra|zeebe)               echo "orchestration" ;;
    elasticsearch|es)              echo "elasticsearch" ;;
    postgres|camunda-db|web-modeler-websockets)
                                   echo "$1" ;;
    restapi|modeler|web-modeler)   echo "web-modeler-restapi" ;;
    websockets)                    echo "web-modeler-websockets" ;;
    all)                           echo "ALL" ;;
    *) echo "ERROR: unknown component: $1" >&2; exit 2 ;;
  esac
}

ALL_NAMES='^(reverse-proxy|orchestration|connectors|optimize|identity|keycloak|postgres|camunda-db|web-modeler-db|mailpit|web-modeler-restapi|web-modeler-websockets|console|elasticsearch|autoheal|camunda-data-init)$'

declare -A SEEN=()
for comp in "${COMPONENTS[@]}"; do
  resolved="$(resolve "$comp")"
  if [[ "$resolved" == "ALL" ]]; then
    targets=$(docker ps -a --format '{{.Names}}' | grep -E "$ALL_NAMES" || true)
  else
    targets="$resolved"
  fi

  for c in $targets; do
    [[ -n "${SEEN[$c]:-}" ]] && continue
    SEEN[$c]=1
    if ! docker inspect "$c" >/dev/null 2>&1; then
      echo "WARN: container '$c' not found — does it exist? (stack running?)" >&2
      continue
    fi

    args=()
    $FOLLOW && args+=(-f)
    args+=(--tail "$TAIL")
    [[ -n "$SINCE" ]] && args+=(--since "$SINCE")

    if [[ -n "$GREP_PATTERN" ]]; then
      echo "===== $c (grep: $GREP_PATTERN) ====="
      docker logs "${args[@]}" "$c" 2>&1 | grep -E --ignore-case "$GREP_PATTERN" || true
    else
      echo "===== $c ====="
      docker logs "${args[@]}" "$c" 2>&1 || true
    fi
    $FOLLOW && break
  done
done
