#!/usr/bin/env bash
set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }
need curl; need jq

# Configs
GH_API="https://api.github.com"
ORG=""
PREFIX=""
BOT_USER=""
REQUIRED_CHECK_NAME="build"

# help doc
usage() {
    cat << EOF
GitHub Repository Automation Script

Usage: $0 -o ORG -p PREFIX -b BOT_USER

Required Options:
  -o, --org ORG              Organization name
  -p, --prefix PREFIX        Repository prefix to target
  -b, --bot-user BOT_USER    Bot username for collaboration

Environment Variables:
  GH_TOKEN                   GitHub Personal Access Token (required)

Example:
  export GH_TOKEN=your_token_here
  $0 -o my-org -p app- -b my-bot
EOF
}

# arguments parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--org) ORG="$2"; shift 2 ;;
        -p|--prefix) PREFIX="$2"; shift 2 ;;
        -b|--bot-user) BOT_USER="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# inputs validation
[[ -z "$ORG" ]] && { echo "Error: Organization required (-o)"; usage; exit 1; }
[[ -z "$PREFIX" ]] && { echo "Error: Prefix required (-p)"; usage; exit 1; }
[[ -z "$BOT_USER" ]] && { echo "Error: Bot user required (-b)"; usage; exit 1; }
[[ -z "${GH_TOKEN:-}" ]] && { echo "Error: GH_TOKEN environment variable required"; echo "Set it with: export GH_TOKEN=your_token_here"; exit 1; }

echo "GitHub Repository Automation"
echo "Organization: $ORG | Prefix: $PREFIX | Bot: $BOT_USER"
echo "-----------------------------------------------------------"

# API setup
HDR=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
api() { curl -sS "${HDR[@]}" "$@"; }
status() { curl -s -o /dev/null -w "%{http_code}" "${HDR[@]}" "$@"; }

# teams discovery
get_all_teams() {
    local page=1
    local per_page=100
    local all_teams="[]"
    local url="${GH_API}/orgs/${ORG}/teams?per_page=${per_page}&page=${page}"
    while :; do
        # Get both headers and body
        local response
        response=$(curl -sS -D - -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" "$url")
        local body headers
        body=$(echo "$response" | awk '/^\r?$/ {found=1; next} found')
        headers=$(echo "$response" | awk '/^\r?$/ {exit} {print}')
        if echo "$body" | jq -e '.message' >/dev/null 2>&1; then
            echo "ERROR: Cannot access teams - $(echo "$body" | jq -r '.message')"
            echo "Please ensure your GH_TOKEN has 'read:org' permissions"
            exit 1
        fi
        all_teams=$(jq -s 'add' <(echo "$all_teams") <(echo "$body"))
        # Check for next page in Link header
        local next_link
        next_link=$(echo "$headers" | grep -i '^Link:' | grep -o '<[^>]*>; rel="next"' | grep -o '<[^>]*>' | tr -d '<>')
        if [[ -z "$next_link" ]]; then
            break
        fi
        url="$next_link"
    done
    echo "$all_teams"
}

find_team() {
    local teams="$1" name="$2"
    jq -r --arg name "$name" '
        map(select((.name|ascii_downcase) == ($name|ascii_downcase))) | 
        .[0].slug // empty' <<<"$teams"
}

echo "Discovering teams..."
ALL_TEAMS=$(get_all_teams)
DEVELOPERS=$(find_team "$ALL_TEAMS" "Developers")
MAINTAINERS=$(find_team "$ALL_TEAMS" "Maintainers")
ADMINS=$(find_team "$ALL_TEAMS" "Instance-Admins")

echo "All teams in organization '$ORG':"
echo "$ALL_TEAMS" | jq -r '.[] | "  - " + .name + " (slug: " + .slug + ")" + (if .parent != null then " [parent: " + .parent.name + "]" else "" end)'

for team_pair in "Developers:$DEVELOPERS" "Maintainers:$MAINTAINERS" "Instance-Admins:$ADMINS"; do
    name="${team_pair%%:*}"
    slug="${team_pair#*:}"
    if [[ -z "$slug" ]]; then
        echo "ERROR: Team '$name' not found"
        exit 1
    fi
    echo "✓ $name team: $slug"
done

# get repos using prefix
get_repos() {
    api "${GH_API}/orgs/${ORG}/repos?per_page=100&type=all" | 
    jq -r '.[].name' | 
    awk -v prefix="$PREFIX" 'index($0,prefix)==1'
}

# create dev branch if missing
create_development_branch() {
    local repo="$1"
    local status_code
    status_code=$(status "${GH_API}/repos/${ORG}/${repo}/branches/development")
    
    if [[ "$status_code" == "200" ]]; then
        echo "  ✓ Development branch exists"
        return
    fi
    
    local default_branch commit_sha
    default_branch=$(api "${GH_API}/repos/${ORG}/${repo}" | jq -r '.default_branch')
    commit_sha=$(api "${GH_API}/repos/${ORG}/${repo}/git/refs/heads/${default_branch}" | jq -r '.object.sha')
    
    api -X POST "${GH_API}/repos/${ORG}/${repo}/git/refs" \
        -d "{\"ref\":\"refs/heads/development\",\"sha\":\"${commit_sha}\"}" >/dev/null
    echo "  ✓ Created development branch"
}

# add bot as collaborator
add_bot_collaborator() {
    local repo="$1"
    local user_status
    user_status=$(status "${GH_API}/users/${BOT_USER}")
    
    [[ "$user_status" != "200" ]] && { echo "  ⚠ Bot user not found"; return; }
    
    local invite_status
    invite_status=$(status -X PUT "${GH_API}/repos/${ORG}/${repo}/collaborators/${BOT_USER}" \
        -d '{"permission":"maintain"}')
    
    case "$invite_status" in
        201) echo "  ✓ Bot invited" ;;
        204) echo "  ✓ Bot already added" ;;
        *) echo "  ⚠ Bot invitation failed" ;;
    esac
}

# protect branch with rules
protect_branch() {
    local repo="$1" branch="$2" approvals="$3"
    shift 3
    
    local users=() teams=()
    for item in "$@"; do
        [[ "$item" == user:* ]] && users+=("\"${item#user:}\"")
        [[ "$item" == team:* ]] && teams+=("\"${item#team:}\"")
    done
    
    local users_json="[]" teams_json="[]"
    [[ ${#users[@]} -gt 0 ]] && users_json="[$(IFS=,; echo "${users[*]}")]"
    [[ ${#teams[@]} -gt 0 ]] && teams_json="[$(IFS=,; echo "${teams[*]}")]"
    
    local protection_rules
    protection_rules=$(jq -n \
        --argjson approvals "$approvals" \
        --argjson users "$users_json" \
        --argjson teams "$teams_json" \
        --arg check "$REQUIRED_CHECK_NAME" '{
            required_status_checks: {strict: true, contexts: [$check]},
            enforce_admins: true,
            required_pull_request_reviews: {
                required_approving_review_count: $approvals,
                dismiss_stale_reviews: true
            },
            restrictions: {users: $users, teams: $teams, apps: []},
            required_conversation_resolution: true,
            allow_force_pushes: false,
            allow_deletions: false
        }')
    
    api -X PUT "${GH_API}/repos/${ORG}/${repo}/branches/${branch}/protection" \
        -d "$protection_rules" >/dev/null
    echo "  ✓ Protected $branch ($approvals approvals required)"
}

# repository settings
configure_repo_settings() {
    local repo="$1"
    local settings='{
        "delete_branch_on_merge": true,
        "allow_auto_merge": true,
        "allow_squash_merge": true,
        "allow_merge_commit": false,
        "allow_rebase_merge": false
    }'
    
    api -X PATCH "${GH_API}/repos/${ORG}/${repo}" -d "$settings" >/dev/null
    echo "  ✓ Repository settings configured"
}

# main
repos=$(get_repos)
[[ -z "$repos" ]] && { echo "No repositories found with prefix '$PREFIX'"; exit 0; }

echo
echo "Processing repositories:"
echo "$repos" | sed 's/^/  • /'
echo

while IFS= read -r repo; do
    echo "[$repo]"
    create_development_branch "$repo"
    add_bot_collaborator "$repo"
    # (grant access removed by request)
    protect_branch "$repo" "master" 2 "team:$DEVELOPERS" "team:$MAINTAINERS"
    protect_branch "$repo" "development" 1 "team:$ADMINS" "user:$BOT_USER"
    configure_repo_settings "$repo"
    echo
done <<< "$repos"

echo "✓ All repositories configured successfully!"
