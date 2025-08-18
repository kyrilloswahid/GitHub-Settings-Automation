# GitHub Repository Automation Script

This script automates the configuration of GitHub repositories within an organization. It performs the following actions for all repositories matching a specified prefix:

- Ensures a `development` branch exists (creates it if missing)
- Adds a specified bot user as a collaborator
- Protects the `master` and `development` branches with review and status check requirements
- Configures repository settings (e.g., enables auto-merge, disables merge commits)

## Usage

```sh
export GH_TOKEN=your_github_token
./github_repo_automation_script.sh -o ORG_NAME -p REPO_PREFIX -b BOT_USER
```

### Required Options

- `-o`, `--org` &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Organization name (e.g., `my-org`)
- `-p`, `--prefix` &nbsp;&nbsp;&nbsp;Repository name prefix to target (e.g., `app-`)
- `-b`, `--bot-user` &nbsp;Bot GitHub username to add as collaborator

### Environment Variables

- `GH_TOKEN` &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;GitHub Personal Access Token (must have `repo` and `read:org` scopes)

### Example

```sh
export GH_TOKEN=your_token_here
./test.sh -o my-org -p app- -b my-bot
```

## What the Script Does

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
