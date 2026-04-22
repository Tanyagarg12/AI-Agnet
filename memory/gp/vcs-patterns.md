# GP VCS Patterns

Accumulated learnings from version control operations across GP pipeline runs.
Updated by `gp-learner-agent` after each run.

---

## GitHub

### Auth
- `GH_TOKEN` or `GITHUB_TOKEN` both work for `gh` CLI
- Token needs `repo` scope for private repositories
- For public repos: `public_repo` scope is sufficient

### PR Creation
- `gh pr create` outputs the PR URL on the last line of stdout
- Use `--fill` to auto-populate from commit messages (useful for quick PRs)
- Draft PRs: add `--draft` flag when tests are incomplete
- Link to issue: add `Closes #<issue_number>` in PR body

### Branch Naming
- Format: `test/<TICKET_ID>-<slug>` — GitHub supports `/` in branch names
- Slug: lowercase, hyphens, max 30 chars: `echo "TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-30`

### Common Issues
- "Branch already exists": Check if previous pipeline run left a branch; increment with `-v2`
- Push rejected (non-fast-forward): Branch diverged; create a new branch name with timestamp
- Rate limit: 5000 API requests/hour; `gh` CLI handles auth efficiently

---

## GitLab

### Auth
- `GITLAB_TOKEN` for `glab` CLI
- Token needs `api` scope
- `glab` config: `glab config set token $GITLAB_TOKEN`

### MR Creation
- `glab mr create --yes` skips confirmation prompt (required for unattended runs)
- `glab mr create` opens editor by default without `--description` flag; always provide body
- Target branch: `--target-branch` (not `--base`)
- MR URL: parse from `glab mr create` stdout

### Branch Naming
- Same format as GitHub: `test/<TICKET_ID>-<slug>`
- GitLab allows `/` in branch names

### Common Issues
- `glab: command not found`: Install glab or use curl with GitLab API directly
- MR already exists: `glab mr list --source-branch <branch>` to find it
- Push to protected branch: Check GitLab project settings for protected branch rules

---

## Azure Repos

### Auth
- `az` CLI with `devops` extension: `az extension add --name azure-devops`
- PAT token: `az devops configure --defaults organization=$ADO_ORG`
- Basic auth alternative: `curl -u ":${ADO_PAT}"` (colon before PAT)

### PR Creation
- `az repos pr create --output json` — parse PR URL from `webUrl` field
- Required: `--org`, `--project`, `--target-branch`
- Reviewers: `--reviewers "user@email.com"`

### Branch Naming
- Same format: `test/<TICKET_ID>-<slug>`
- Azure Repos supports `/` in branch names

### Commit Strategy (All Providers)

**Commit in this order** for GP pipeline:
1. `feat(selectors): add <TICKET_ID> selectors` — selector JSON files
2. `feat(pages): add <PageName> POM class` — one commit per page
3. `feat(helpers): add <feature> test helpers` — helper functions
4. `feat(tests): add <TICKET_ID> - <feature> test` — the test file

**Each fix gets its own commit**:
- `fix(tests): update selector for <element> — <reason>`
- `fix(tests): add waitForResponse for <endpoint>`

**Branch conventions**:
- Create branch from target branch: `git checkout -b test/... origin/main`
- Never commit directly to protected branches
- Always push with `-u origin <branch>` on first push
