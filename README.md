# GitHub Repository Automation Script

This script automates the configuration of GitHub repositories within an organization. It performs the following actions for all repositories matching a specified prefix:
- Ensures a `development` branch exists (creates it if missing)
- Adds a specified bot user as a collaborator
- Protects the `master` and `development` branches with review and status check requirements
- Configures repository settings (e.g., enables auto-merge, disables merge commits)

## Settings Equivalence Table

| GitLab Setting                        | GitHub Equivalent                       |
|-----------------------------------------------------|---------------------------------------------------|
| only_allow_merge_if_pipeline_succeeds: true         | required_status_checks: { strict: true, contexts: [$check] } |
| only_allow_merge_if_all_discussions_are_resolved: true | required_conversation_resolution: true           |
| remove_source_branch_after_merge: true              | delete_branch_on_merge: true                      |
| auto_cancel_pending_pipelines: "enabled"           | concurrency (in workflow YAML)                    |
| ci_forward_deployment_enabled: true                 | deploy_production job (in workflow YAML)          |
| ci_forward_deployment_rollback_allowed: true        | rollback_production job (in workflow YAML)        |
| ci_separated_caches: true                           | GitHub Actions cache with separate keys (workflow) |
| build_git_strategy: "fetch"                        | fetch-depth: 0 (in workflow YAML)                 |
| public_jobs: false                                  | No direct equivalent; jobs are private in private repos |
| ci_pipeline_variables_minimum_override_role: "developer" | No direct equivalent; handled by repo/environment permissions |
| delete_branch_on_merge: true                        | delete_branch_on_merge: true                      |
| allow_auto_merge: true                              | allow_auto_merge: true                            |
| allow_squash_merge: true                            | allow_squash_merge: true                          |
| allow_merge_commit: false                           | allow_merge_commit: false                         |
| allow_rebase_merge: false                           | allow_rebase_merge: false                         |

## Implementation & Relevance Table

| Setting                        | Script Level | Workflow Level | No Equivalence | Description                                                               |
|------------------------------------------|:------------:|:--------------:|:--------------:|-----------------------------------------------------------------------------------------------|
| delete_branch_on_merge                   |      ✔       |                |                | Deletes branch after merge, keeps repos clean, standardizes behavior                          |
| allow_auto_merge                         |      ✔       |                |                | Enables auto-merge for PRs that meet all requirements                                         |
| allow_squash_merge                       |      ✔       |                |                | Allows squash merging, cleaner commit history                                                 |
| allow_merge_commit                       |      ✔       |                |                | Disables merge commits, enforces linear history                                               |
| allow_rebase_merge                       |      ✔       |                |                | Disables rebase merging, standardizes merge strategy                                          |
| required_status_checks                   |      ✔       |                |                | Enforces CI must pass before merging (pipeline succeeds)                                      |
| required_conversation_resolution         |      ✔       |                |                | Requires all discussions to be resolved before merging                                        |
| concurrency (auto_cancel_pending_pipelines) |            |      ✔         |                | Cancels in-progress workflows for same PR, set in workflow YAML                              |
| deploy_production/rollback_production    |              |      ✔         |                | Forward deployment/rollback jobs, set in workflow YAML                                       |
| cache with separate keys                 |              |      ✔         |                | Ensures separate caches for jobs, set in workflow YAML                                       |
| fetch-depth: 0                           |              |      ✔         |                | Ensures full git history for builds, set in workflow YAML                                    |
| public_jobs                              |              |                |      ✔         | Not directly supported; jobs are private in private repos, public in public repos            |
| ci_pipeline_variables_minimum_override_role |            |                |      ✔         | Not directly supported; handled by repo/environment permissions                               |


## Logical Flow of the Script

1. **Preparation**
	- The script checks for required tools (`curl`, `jq`) using the `need()` function and validates that all necessary arguments and the GitHub token are provided.
	- It sets up API headers for authenticated requests and defines helper functions for API calls (`api()` and `status()`).

2. **Team Discovery**
	- `get_all_teams()`: Fetches all teams in the organization, handling pagination to ensure no teams are missed.
	- `find_team()`: Finds a team by name in the teams JSON and returns its slug.
	- The script uses these to identify the key teams: Developers, Maintainers, and Instance-Admins. If any are missing, it prints all available teams and exits with a clear error.

3. **Repository Discovery**
	- `get_repos()`: Fetches all repositories in the organization (with pagination), filters them by the specified prefix, and outputs the repo names.

4. **Per-Repository Automation**
	- For each matching repository, the script:
	  - `create_development_branch()`: Ensures a `development` branch exists (creating it from the default branch if needed).
	  - `add_bot_collaborator()`: Adds the DevOps bot as a collaborator with the correct permissions.
	  - Detects the default branch (main/master) and applies branch protection rules:
		 - `protect_branch()`: Sets branch protection rules for both the default and development branches, enforcing the required teams and approval counts.
	  - `configure_repo_settings()`: Configures repository settings to standardize merge strategies and branch deletion.

5. **Completion**
	- After processing all repositories, the script prints a success message.

---

## Usage

```sh
export GH_TOKEN=your_github_token
./github_repo_automation_script.sh -o ORG_NAME -p REPO_PREFIX -b BOT_USER -t PARENT_TEAM
```

### Required Options

- `-o`, `--org` &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Organization name (e.g., `my-org`)
- `-p`, `--prefix` &nbsp;&nbsp;&nbsp;Repository name prefix to target (e.g., `app-`)
- `-b`, `--bot-user` &nbsp;Bot GitHub username to add as collaborator
- `-t`, `--parent-team` &nbsp;Parent team name to list its childs

### Environment Variables

- `GH_TOKEN` &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;GitHub Personal Access Token (must have `repo` and `read:org` scopes)

## Summary

1. **Discovers Teams:** Looks for teams named `Developers`, `Maintainers`, and `Instance-Admins` in the organization.
2. **Finds Target Repositories:** Lists all repositories in the organization whose names start with the given prefix.
3. **For Each Repository:**
	- Ensures a `development` branch exists.
	- Adds the bot user as a collaborator with `maintain` permission.
	- Protects the `master` branch (requires 2 approvals from `Developers` or `Maintainers`).
	- Protects the `development` branch (requires 1 approval from `Instance-Admins` or the bot user).
	- Configures repository settings (enables auto-merge, disables merge commits, etc.).

## Requirements

- `bash`
- `curl`
- `jq`

## Notes

- The script must be run with a valid GitHub token in the `GH_TOKEN` environment variable.
- The token must have sufficient permissions to read organization teams and modify repository settings.
- If any required team is missing, the script will display an error and exit.
- Granting team access to repositories is handled via a configuration file and is not addressed by this script.
