#!/bin/bash
# Validates acli Jira commands against safety rules.
# Blocks: ticket deletion, type changes, reassignment, summary/description edits, non-OXDEV writes.
# Runs as a PreToolUse hook for Bash tool calls.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only validate acli commands
if ! echo "$COMMAND" | grep -q 'acli '; then
  exit 0
fi

# Load project scope from policy if available
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JIRA_PROJECT_SCOPE=$(python3 "$SCRIPT_DIR/load-policy.py" _common --field jira.project_scope 2>/dev/null | tr -d '"' || true)
: "${JIRA_PROJECT_SCOPE:=OXDEV}"

# --- Block delete operations ---
if echo "$COMMAND" | grep -qiE 'acli\s+jira\s+workitem\s+(delete|remove)'; then
  echo '{"decision":"block","reason":"Jira ticket deletion is not allowed by OX E2E agent safety rules."}'
  exit 0
fi

if echo "$COMMAND" | grep -qiE 'acli\s+jira\s+workitem\s+comment\s+(delete|remove)'; then
  echo '{"decision":"block","reason":"Jira comment deletion is not allowed by OX E2E agent safety rules."}'
  exit 0
fi

# --- Block forbidden edit operations ---
if echo "$COMMAND" | grep -qiE 'acli\s+jira\s+workitem\s+edit'; then
  # Block changing issue type
  if echo "$COMMAND" | grep -qE '\s--type\s'; then
    echo '{"decision":"block","reason":"Changing Jira ticket issue type is not allowed by OX E2E agent safety rules."}'
    exit 0
  fi

  # Block reassigning tickets
  if echo "$COMMAND" | grep -qE '\s(--assignee|-a)\s'; then
    echo '{"decision":"block","reason":"Reassigning Jira tickets is not allowed by OX E2E agent safety rules."}'
    exit 0
  fi

  # Block modifying summary
  if echo "$COMMAND" | grep -qE '\s(--summary|-s)\s'; then
    echo '{"decision":"block","reason":"Modifying Jira ticket summary is not allowed by OX E2E agent safety rules."}'
    exit 0
  fi

  # Block modifying description
  if echo "$COMMAND" | grep -qE '\s(--description|-d|--description-file)\s'; then
    echo '{"decision":"block","reason":"Modifying Jira ticket description is not allowed by OX E2E agent safety rules."}'
    exit 0
  fi

  # Block changing priority
  if echo "$COMMAND" | grep -qE '\s--priority\s'; then
    echo '{"decision":"block","reason":"Changing Jira ticket priority is not allowed by OX E2E agent safety rules."}'
    exit 0
  fi
fi

# --- Enforce OXDEV project scope for write operations ---
# Allow reads (search, view, comment list) on any project
if echo "$COMMAND" | grep -qiE 'acli\s+jira\s+workitem\s+(search|view|comment\s+list)'; then
  exit 0
fi

# For create/edit/comment-create operations, ensure project is OXDEV
if echo "$COMMAND" | grep -qiE 'acli\s+jira\s+workitem\s+(create|edit|comment)'; then
  # Check --project flag
  NON_OXDEV_PROJECT=$(echo "$COMMAND" | grep -oE '\s(--project|-p)\s+"?([A-Z]+)"?' | grep -v 'OXDEV' | head -1)
  if [ -n "$NON_OXDEV_PROJECT" ]; then
    echo '{"decision":"block","reason":"Write operations outside Jira project OXDEV are not allowed."}'
    exit 0
  fi

  # Check --key flag for non-OXDEV ticket keys
  NON_OXDEV_KEY=$(echo "$COMMAND" | grep -oE '\s(--key|-k)\s+"?[A-Z]+-[0-9]+' | grep -v 'OXDEV-' | head -1)
  if [ -n "$NON_OXDEV_KEY" ]; then
    echo '{"decision":"block","reason":"Write operations on tickets outside Jira project OXDEV are not allowed."}'
    exit 0
  fi

  # Check --jql flag for non-OXDEV project references in writes
  if echo "$COMMAND" | grep -qE '\s--jql\s'; then
    JQL_PROJECT=$(echo "$COMMAND" | grep -oE 'project\s*=\s*"?[A-Z]+' | grep -oE '[A-Z]+$' | head -1)
    if [ -n "$JQL_PROJECT" ] && [ "$JQL_PROJECT" != "OXDEV" ]; then
      echo '{"decision":"block","reason":"Write operations outside Jira project OXDEV are not allowed. Found project: '"$JQL_PROJECT"'"}'
      exit 0
    fi
  fi
fi

exit 0
