#!/usr/bin/env bash
set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }
need curl; need jq

# Default values
GH_API="https://api.github.com"
ORG=""
PREFIX=""
BOT_USER=""
REQUIRED_CHECK_NAME="${REQUIRED_CHECK_NAME:-}"

# Usage function
usage() {
    cat << EOF
GitHub Org Settings Automation

Usage: $0 [OPTIONS]

Required Options:
  -o, --org ORG              Organization name (e.g., ucc-test-org)
  -p, --prefix PREFIX        Repo name prefix to target (e.g., uh-)
  -b, --bot-user BOT_USER    Bot GitHub username (e.g., Cloud-Platforms-DevOps-Bot)

Optional Options:
  -a, --api-url URL          GitHub API base URL (default: https://api.github.com)
  -c, --check-name NAME      Required CI check name (can also use REQUIRED_CHECK_NAME env var)
  -h, --help                 Show this help message

Environment Variables:
  GITHUB_TOKEN              GitHub Personal Access Token (required)
  REQUIRED_CHECK_NAME       Required CI check name (optional)

Examples:
  $0 -o ucc-test-org -p uh- -b Cloud-Platforms-DevOps-Bot
  $0 --org myorg --prefix app- --bot-user mybot --api-url https://github.company.com/api/v3
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--org)
            ORG="$2"
            shift 2
            ;;
        -p|--prefix)
            PREFIX="$2"
            shift 2
            ;;
        -b|--bot-user)
            BOT_USER="$2"
            shift 2
            ;;
        -a|--api-url)
            GH_API="$2"
            shift 2
            ;;
        -c|--check-name)
            REQUIRED_CHECK_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$ORG" ]]; then
    echo "Error: Organization name is required (-o/--org)"
    usage
    exit 1
fi

if [[ -z "$PREFIX" ]]; then
    echo "Error: Repo prefix is required (-p/--prefix)"
    usage
    exit 1
fi

if [[ -z "$BOT_USER" ]]; then
    echo "Error: Bot username is required (-b/--bot-user)"
    usage
    exit 1
fi

# Check for GitHub token in environment
GH_TOKEN="${GITHUB_TOKEN:-}"
if [[ -z "$GH_TOKEN" ]]; then
    echo "Error: GITHUB_TOKEN environment variable is required"
    echo "Set it with: export GITHUB_TOKEN=your_token_here"
    exit 1
fi

echo "GitHub Org Settings Automation"
echo "--------------------------------"
echo "Organization: $ORG"
echo "Repo prefix: $PREFIX"
echo "Bot user: $BOT_USER"
echo "API URL: $GH_API"

HDR=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" -H "Content-Type: application/json")
api() { curl -sS "${HDR[@]}" "$@"; }
status() { curl -s -o /dev/null -w "%{http_code}" "${HDR[@]}" "$@"; }

# ---- Team discovery (no prompts) ----
get_all_teams() {
  local page=1 out="[]"
  while :; do
    local chunk
    chunk=$(api "${GH_API}/orgs/${ORG}/teams?per_page=100&page=${page}")
    [[ "$(jq 'length' <<<"$chunk")" == "0" ]] && break
    out=$(jq -s 'add' <(echo "$out") <(echo "$chunk"))
    page=$((page+1))
  done
  echo "$out"
}
resolve_slug() {
  local teams="$1" want="$2"
  jq -r --arg w "$want" '
    map(select(
      (.name|ascii_downcase)==($w|ascii_downcase) or
      (.slug|ascii_downcase)==($w|ascii_downcase)
    )) | .[0].slug // empty' <<<"$teams"
}

ALL_TEAMS_JSON="$(get_all_teams)"
DEV_TEAM="$(resolve_slug "$ALL_TEAMS_JSON" "Developers")"; [[ -z "$DEV_TEAM" ]] && DEV_TEAM="$(resolve_slug "$ALL_TEAMS_JSON" "developers")"
MAINTAINERS_TEAM="$(resolve_slug "$ALL_TEAMS_JSON" "Maintainers")"; [[ -z "$MAINTAINERS_TEAM" ]] && MAINTAINERS_TEAM="$(resolve_slug "$ALL_TEAMS_JSON" "maintainers")"
ADMINS_TEAM="$(resolve_slug "$ALL_TEAMS_JSON" "Instance Admins")"; [[ -z "$ADMINS_TEAM" ]] && ADMINS_TEAM="$(resolve_slug "$ALL_TEAMS_JSON" "instance-admins")"

for pair in "Developers:$DEV_TEAM" "Maintainers:$MAINTAINERS_TEAM" "Instance Admins:$ADMINS_TEAM"; do
  key="${pair%%:*}"; val="${pair#*:}"
  if [[ -z "$val" ]]; then
    echo "ERROR: Missing team \"$key\" in org \"$ORG\"."
    jq -r '.[] | "- " + .name + " (slug: " + .slug + ")"' <<<"$ALL_TEAMS_JSON"
    exit 1
  fi
done

echo "Teams detected:"
echo " - Developers       -> $DEV_TEAM"
echo " - Maintainers      -> $MAINTAINERS_TEAM"
echo " - Instance Admins  -> $ADMINS_TEAM"
[[ -n "$REQUIRED_CHECK_NAME" ]] && echo "Required CI check: $REQUIRED_CHECK_NAME" || echo "Required CI check: (none)"

list_repos() {
  api "${GH_API}/orgs/${ORG}/repos?per_page=100&type=all" \
  | jq -r '.[].name' \
  | awk -v pfx="$PREFIX" 'index($0,pfx)==1'
}
ensure_branch() {
  local repo="$1" branch="$2"
  local code; code=$(status "${GH_API}/repos/${ORG}/${repo}/branches/${branch}")
  if [[ "$code" == "200" ]]; then echo "  ✔ branch '${branch}' exists"; return; fi
  local default sha
  default=$(api "${GH_API}/repos/${ORG}/${repo}" | jq -r '.default_branch')
  sha=$(api "${GH_API}/repos/${ORG}/${repo}/git/refs/heads/'"$default"'" | jq -r '.object.sha')
  api -X POST "${GH_API}/repos/${ORG}/${repo}/git/refs" -d "{\"ref\":\"refs/heads/${branch}\",\"sha\":\"${sha}\"}" >/dev/null
  echo "  ✔ created branch '${branch}' from '${default}'"
}
add_bot_collaborator() {
  local repo="$1"
  local ucode; ucode=$(status "${GH_API}/users/${BOT_USER}")
  if [[ "$ucode" != "200" ]]; then echo "  ⚠ bot user '${BOT_USER}' does not exist (skipping invite)"; return; fi
  local code; code=$(status -X PUT "${GH_API}/repos/${ORG}/${repo}/collaborators/${BOT_USER}" -d '{"permission":"maintain"}')
  case "$code" in
    201) echo "  ✔ invite sent to '${BOT_USER}' (pending)";;
    204) echo "  ✔ '${BOT_USER}' already collaborator";;
    404) echo "  ⚠ cannot invite '${BOT_USER}' (visibility/policy)";;
    *)   echo "  ⚠ collaborator API HTTP $code";;
  esac
}
grant_team_access() {
  local team_slug="$1" repo="$2" perm="${3:-push}"
  local code; code=$(status -X PUT "${GH_API}/orgs/${ORG}/teams/${team_slug}/repos/${ORG}/${repo}" -d "{\"permission\":\"${perm}\"}")
  [[ "$code" == "204" ]] && echo "  ✔ team '${team_slug}' -> '${repo}' (${perm})" || echo "  ⚠ team access HTTP $code for '${team_slug}'"
}
protect_branch() {
  local repo="$1" branch="$2" approvals="$3"; shift 3
  local users_json="[]" teams_json="[]"; local users=() teams=()
  for item in "$@"; do [[ "$item" == user:* ]] && users+=("\"${item#user:}\""); [[ "$item" == team:* ]] && teams+=("\"${item#team:}\""); done
  [[ ${#users[@]} -gt 0 ]] && users_json="[$(IFS=,; echo "${users[*]}")]"
  [[ ${#teams[@]} -gt 0 ]] && teams_json="[$(IFS=,; echo "${teams[*]}")]"
  local rsc; if [[ -n "$REQUIRED_CHECK_NAME" ]]; then rsc=$(jq -n --arg name "$REQUIRED_CHECK_NAME" '{strict:true,contexts:[$name]}'); else rsc=null; fi
  local body; body=$(jq -n --argjson approvals "$approvals" --argjson users "$users_json" --argjson teams "$teams_json" --argjson checks "$rsc" '
    { required_status_checks:$checks, enforce_admins:true,
      required_pull_request_reviews:{ required_approving_review_count:($approvals|tonumber), dismiss_stale_reviews:true },
      restrictions:{ users:$users, teams:$teams, apps:[] },
      required_conversation_resolution:true, allow_force_pushes:false, allow_deletions:false, block_creations:false }')
  api -X PUT "${GH_API}/repos/${ORG}/${repo}/branches/${branch}/protection" -d "$body" >/dev/null
  local msg="approvals: ${approvals}"; [[ -n "$REQUIRED_CHECK_NAME" ]] && msg+="; requires check: ${REQUIRED_CHECK_NAME}"
  echo "  ✔ protected '${branch}' (${msg})"
}
set_repo_toggles() {
  local repo="$1"
  api -X PATCH "${GH_API}/repos/${ORG}/${repo}" -d '{"delete_branch_on_merge":true,"allow_auto_merge":true}' >/dev/null
  echo "  ✔ repo toggles set (delete_branch_on_merge, allow_auto_merge)"
}

repos=$(list_repos)
if [[ -z "$repos" ]]; then echo "No repositories in '${ORG}' start with '${PREFIX}'."; exit 0; fi
echo "Processing repos:"; echo "$repos" | sed 's/^/ - /'; echo "--------------------------------"

while IFS= read -r REPO; do
  echo "[${REPO}]"
  ensure_branch "$REPO" "development"
  add_bot_collaborator "$REPO"
  grant_team_access "$DEV_TEAM" "$REPO" "push"
  grant_team_access "$MAINTAINERS_TEAM" "$REPO" "maintain"
  grant_team_access "$ADMINS_TEAM" "$REPO" "maintain"
  protect_branch "$REPO" "master" 2 "team:${DEV_TEAM}" "team:${MAINTAINERS_TEAM}"
  protect_branch "$REPO" "development" 1 "team:${ADMINS_TEAM}" "user:${BOT_USER}"
  set_repo_toggles "$REPO"
  echo
done <<< "$repos"

echo "All done."
