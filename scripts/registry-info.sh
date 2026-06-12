#!/usr/bin/env bash
# Inspect Camunda's private Docker registry (Harbor v2 API): projects, repositories, tags.
#
# Reads CAMUNDA_REGISTRY_URL from .env and CAMUNDA_REGISTRY_USERNAME /
# CAMUNDA_REGISTRY_PASSWORD from .env-credentials. With no arguments, lists
# the newest tags for the images used by docker-compose.yaml.
#
# Requires: curl, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
CREDENTIALS_FILE="$PROJECT_DIR/.env-credentials"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]
  -p, --projects                 List all projects visible to the configured account
  -P, --project <name>           List repositories in <name> (or, with -r, list tags)
  -r, --repository <name>        Repository (e.g. "camunda/console"). Requires --project.
  -l, --limit <n>                Number of tags to show per repository (default 10)
  -h, --help                     Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --projects
  $(basename "$0") --project hotfixes
  $(basename "$0") --project dockerhub-camunda --repository camunda/console --limit 20
EOF
}

LIST_PROJECTS=0
PROJECT=""
REPOSITORY=""
LIMIT=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--projects)   LIST_PROJECTS=1; shift ;;
    -P|--project)    PROJECT="${2:-}"; shift 2 ;;
    -r|--repository) REPOSITORY="${2:-}"; shift 2 ;;
    -l|--limit)      LIMIT="${2:-10}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo ".env file not found. It is part of the repo, so this should not happen." >&2
  echo "       Re-clone the repository, or restore .env from your last commit." >&2
  exit 1
fi

if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  echo ".env-credentials file not found." >&2
  echo "       Run: bash scripts/generate-secrets.sh" >&2
  echo "       Or:  cp .env-credentials.example .env-credentials" >&2
  exit 1
fi

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required tool '$cmd' is not installed." >&2
    exit 1
  fi
done

# Reads a KEY=VALUE line from the given env file. Skips comments and strips
# optional surrounding quotes.
read_env() {
  local file="$1" key="$2"
  local value
  value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | head -1 | sed -E "s/^[[:space:]]*${key}[[:space:]]*=//")"
  value="${value%$'\r'}"
  if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$value"
}

REGISTRY_URL="$(read_env "$ENV_FILE"          CAMUNDA_REGISTRY_URL)"
REGISTRY_USER="$(read_env "$CREDENTIALS_FILE" CAMUNDA_REGISTRY_USERNAME)"
REGISTRY_PASSWORD="$(read_env "$CREDENTIALS_FILE" CAMUNDA_REGISTRY_PASSWORD)"

[[ -n "$REGISTRY_URL"      ]] || { echo "CAMUNDA_REGISTRY_URL not set in .env" >&2; exit 1; }
[[ -n "$REGISTRY_USER"     ]] || { echo "CAMUNDA_REGISTRY_USERNAME not set in .env-credentials" >&2; exit 1; }
[[ -n "$REGISTRY_PASSWORD" ]] || { echo "CAMUNDA_REGISTRY_PASSWORD not set in .env-credentials" >&2; exit 1; }

REGISTRY_URL="${REGISTRY_URL%/}"

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

api() {
  curl -fsSL -u "${REGISTRY_USER}:${REGISTRY_PASSWORD}" "${REGISTRY_URL}/api/v2.0/$1"
}

# Harbor stores repos as "<project>/<repo>". Strip the leading "<project>/" so
# callers can copy-paste the full name from the repositories listing and still
# hit the artifacts endpoint, which expects the bare repo name.
strip_project_prefix() {
  local proj="$1" repo="$2"
  if [[ "$repo" == "${proj}/"* ]]; then
    printf '%s' "${repo#${proj}/}"
  else
    printf '%s' "$repo"
  fi
}

show_tags() {
  local proj="$1" repo="$2" take="$3"
  repo="$(strip_project_prefix "$proj" "$repo")"
  local page_size=$(( take * 2 ))
  (( page_size < 20 )) && page_size=20
  api "projects/$(urlencode "$proj")/repositories/$(urlencode "$repo")/artifacts?with_tag=true&page_size=${page_size}" |
    jq -r --argjson n "$take" \
      '[.[] | select(.tags) | .tags[] | {name, push_time}]
         | sort_by(.push_time) | reverse | .[0:$n]
         | .[] | [.name, .push_time] | @tsv' |
    column -t -s $'\t' -N TAG,PUSHED 2>/dev/null || cat
}

if (( LIST_PROJECTS )); then
  echo "Projects on $REGISTRY_URL"
  api 'projects?page_size=100' |
    jq -r '.[] | [.name, .repo_count, (.metadata.public // false)] | @tsv' |
    sort |
    column -t -s $'\t' -N NAME,REPOS,PUBLIC 2>/dev/null || cat
  exit 0
fi

if [[ -n "$PROJECT" && -z "$REPOSITORY" ]]; then
  echo "Repositories in '$PROJECT'"
  api "projects/$(urlencode "$PROJECT")/repositories?page_size=100" |
    jq -r '.[] | [.name, .artifact_count, .update_time] | @tsv' |
    sort |
    column -t -s $'\t' -N NAME,ARTIFACTS,UPDATED 2>/dev/null || cat
  exit 0
fi

if [[ -n "$PROJECT" && -n "$REPOSITORY" ]]; then
  REPO_BARE="$(strip_project_prefix "$PROJECT" "$REPOSITORY")"
  echo "Tags for $PROJECT/$REPO_BARE (newest $LIMIT)"
  show_tags "$PROJECT" "$REPOSITORY" "$LIMIT"
  exit 0
fi

# Default: tags for the images referenced by docker-compose.yaml
DEFAULTS=(
  "dockerhub-camunda|camunda/camunda"
  "dockerhub-camunda|camunda/console"
  "dockerhub-camunda|camunda/optimize"
  "dockerhub-camunda|camunda/identity"
  "dockerhub-camunda|camunda/connectors-bundle"
  "dockerhub-camunda|camunda/web-modeler-restapi"
  "dockerhub-camunda|camunda/web-modeler-webapp"
  "dockerhub-camunda|camunda/web-modeler-websockets"
  "dockerhub-camunda|camunda/keycloak"
)

for entry in "${DEFAULTS[@]}"; do
  proj="${entry%%|*}"
  repo="${entry##*|}"
  echo "=== $proj/$repo (newest $LIMIT) ==="
  if ! show_tags "$proj" "$repo" "$LIMIT"; then
    echo "  (request failed)"
  fi
  echo
done
