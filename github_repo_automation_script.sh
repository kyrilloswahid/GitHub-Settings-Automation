#!/bin/bash

# ===== Prompt for Inputs =====
read -p "Enter GitHub base URL: " GITHUB_URL
read -p "Enter GitHub Access Token: " GITHUB_TOKEN

PREFIX="uh-"
ORG="UCC-Hub"

# ===== Function to Apply Settings to a Repository ====t
apply_settings() {
    local repo=$1
    echo "Applying settings to $repo ..."

    # 1. Create development branch
    curl -s -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        "$GITHUB_URL/repos/$ORG/$repo/git/refs" \
        -d '{"ref": "refs/heads/development", "sha": "'$(curl -s -H "Authorization: token $GITHUB_TOKEN" $GITHUB_URL/repos/$ORG/$repo/git/refs/heads/master | jq -r .object.sha)'"}'

    # 2. Add Cloud Platforms DevOps Bot as member
    curl -s -X PUT \
        -H "Authorization: token $GITHUB_TOKEN" \
        "$GITHUB_URL/repos/$ORG/$repo/collaborators/Cloud-Platforms-DevOps-Bot" \
        -d '{"permission": "push"}'

    # 3. Protect master branch
    curl -s -X PUT \
        -H "Authorization: token $GITHUB_TOKEN" \
        "$GITHUB_URL/repos/$ORG/$repo/branches/master/protection" \
        -d '{"required_pull_request_reviews":{"required_approving_review_count":2}, "restrictions":{"users":[],"teams":["Developers","Maintainers","Instance-Admins","Cloud Platforms DevOps Bot"]}}'

    # 4. Protect development branch
    curl -s -X PUT \
        -H "Authorization: token $GITHUB_TOKEN" \
        "$GITHUB_URL/repos/$ORG/$repo/branches/development/protection" \
        -d '{"required_pull_request_reviews":{"required_approving_review_count":1}, "restrictions":{"users":[],"teams":["Developers","Maintainers","Instance-Admins","Cloud Platforms DevOps Bot"]}}'

    # 5. Apply project settings equivalent to GitLab JSON
    curl -s -X PATCH \
        -H "Authorization: token $GITHUB_TOKEN" \
        "$GITHUB_URL/repos/$ORG/$repo" \
        -d '{
            "has_issues": true,
            "has_projects": true,
            "allow_merge_commit": false,
            "allow_squash_merge": true,
            "allow_rebase_merge": true
        }'
}

# ===== Main Execution =====
repos=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$GITHUB_URL/orgs/$ORG/repos" | jq -r ".[].name" | grep "^$PREFIX")

for repo in $repos; do
    apply_settings "$repo"
done

echo "All settings applied to repositories with prefix '$PREFIX'."
