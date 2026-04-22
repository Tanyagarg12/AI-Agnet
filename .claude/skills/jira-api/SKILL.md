---
name: jira-api
description: Use when working with Jira tickets via the Atlassian CLI (acli).
---

# Atlassian CLI (acli) -- Jira Operations

## Overview

The `acli` command provides native CLI access to Jira Cloud.
Auth is stored locally after `acli jira auth login`.

## Authentication

Before running any `acli` command, check auth status and re-authenticate if needed:

```bash
# Check auth status -- if it fails, re-authenticate
acli jira auth status 2>/dev/null || echo "$ATLASSIAN_API_TOKEN" | acli jira auth login \
  --site "$ATLASSIAN_SITE_NAME" \
  --email "$ATLASSIAN_USER_EMAIL" \
  --token
```

The env vars `ATLASSIAN_SITE_NAME`, `ATLASSIAN_USER_EMAIL`, `ATLASSIAN_API_TOKEN` are provided via `.claude/settings.local.json` and are available to all agent teammates.

```bash
# Manual login (non-interactive, pipe API token via stdin)
echo "$ATLASSIAN_API_TOKEN" | acli jira auth login \
  --site "$ATLASSIAN_SITE_NAME" \
  --email "$ATLASSIAN_USER_EMAIL" \
  --token

# Check auth status
acli jira auth status
```

## Shell Quoting for JQL

**IMPORTANT**: Always use **double quotes** for the `--jql` flag value, with escaped inner quotes. Single quotes cause `!` in operators like `!=` and `NOT IN` to be interpreted as bash history expansion.

```bash
# CORRECT -- double quotes with escaped inner quotes
acli jira workitem search --jql "project = OXDEV AND labels != \"ai-done\"" --json

# WRONG -- single quotes break on != and NOT IN
acli jira workitem search --jql 'project = OXDEV AND labels != "ai-done"' --json
```

Also avoid `NOT IN (...)` -- use multiple `!=` conditions instead:

```bash
# CORRECT
--jql "labels != \"ai-in-progress\" AND labels != \"ai-done\""

# AVOID
--jql "labels NOT IN (\"ai-in-progress\", \"ai-done\")"
```

## Common Operations

### Search work items (JQL)

```bash
# Search with JQL, return JSON
acli jira workitem search --jql "project = OXDEV AND labels = ai-ready" --json

# Search with field selection
acli jira workitem search --jql "project = OXDEV" --fields "key,summary,status,labels" --limit 10

# Count results
acli jira workitem search --jql "project = OXDEV AND status = 'To Do'" --count
```

### View a work item

```bash
# View issue details
acli jira workitem view OXDEV-123 --json

# View specific fields
acli jira workitem view OXDEV-123 --fields "key,summary,description,labels,status,issuetype,priority"
```

### Edit a work item

```bash
# Add labels
acli jira workitem edit --key "OXDEV-123" --labels "ai-in-progress" --yes

# Remove labels
acli jira workitem edit --key "OXDEV-123" --remove-labels "ai-ready" --yes
```

### Add a comment

```bash
# Add a comment to a work item
acli jira workitem comment create --key "OXDEV-123" --body "**[QA Agent: triage-agent]** 2026-03-06T10:00:00Z

Triage complete. Ticket classified as issues, UI test, complexity M."
```

### List comments

```bash
acli jira workitem comment list --key "OXDEV-123" --json
```

## Flags Reference

| Flag | Description |
|------|-------------|
| `--json` | Output as JSON |
| `--limit N` | Max results to fetch |
| `--paginate` | Fetch all pages |
| `--fields` | Comma-separated field list |
| `--jql` | JQL query string |
| `-y, --yes` | Skip confirmation prompts |

## Quick start

```bash
acli jira --help
acli jira workitem --help
```
