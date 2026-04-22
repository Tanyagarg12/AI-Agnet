---
name: glab-api
description: Use when working with GitLab via the glab CLI for MR creation, branch management, and API queries.
---

# glab CLI -- GitLab Operations

## Overview

The `glab` command provides CLI access to GitLab. Used for creating merge requests, managing branches, and querying the GitLab API.

Authentication is configured via `glab auth login` during setup.

## Common Operations

### Create Merge Request

```bash
glab mr create \
  --source-branch "test/OXDEV-123-my-test" \
  --target-branch "developmentV2" \
  --title "test(issues): OXDEV-123 - Add filter validation test" \
  --description "## Summary
- Add E2E test for issues filter validation

## Ticket
OXDEV-123"
```

### List Merge Requests

```bash
# List open MRs
glab mr list --state opened

# View specific MR
glab mr view <MR-number>
```

### Branch Operations

```bash
# List remote branches
glab api "/projects/:id/repository/branches?per_page=20" | jq '.[] | {name, default: .default}'

# Check if branch exists
git ls-remote --heads origin test/OXDEV-123-my-test
```

### API Queries

**CRITICAL**: All `glab api` endpoints MUST start with `/`.

```bash
# CORRECT -- leading slash required
glab api "/projects/:id/merge_requests?state=opened"

# WRONG -- returns 500 error
glab api "projects/:id/merge_requests"
```

### Search Projects

```bash
# Search within oxsecurity org
glab api "/groups/oxsecurity/projects?search=<keyword>&include_subgroups=true&per_page=20" \
  | jq '.[] | {id, path_with_namespace, web_url}'

# Get specific project
glab api "/projects/oxsecurity%2Fapp%2Fapi" \
  | jq '{id, path_with_namespace, web_url, default_branch}'
```

### URL Encoding

Forward slashes in group/project paths must be `%2F` encoded:

| Group                  | Encoded path               |
|------------------------|----------------------------|
| oxsecurity/app         | `oxsecurity%2Fapp`         |
| oxsecurity/shared      | `oxsecurity%2Fshared`      |
| oxsecurity/backoffice  | `oxsecurity%2Fbackoffice`  |
| oxsecurity/sectools    | `oxsecurity%2Fsectools`    |
| oxsecurity/devops      | `oxsecurity%2Fdevops`      |

## Common Pitfalls

1. **Missing leading `/`** -- All endpoints MUST start with `/`. Without it, glab returns 500 errors.
2. **Using `-f`/`-F` for GET query params** -- The `-f` flag sets POST body fields, NOT query parameters. For GET requests, put params in the URL string.
3. **Using `--paginate` on broad searches** -- Avoid `--paginate` on global `/projects` search; use group-scoped search with `per_page` instead.
4. **Not URL-encoding group paths** -- Forward slashes in group names must be `%2F` encoded.

## Quick start

```bash
glab --help
glab mr --help
glab api --help
```
