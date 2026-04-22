#!/bin/bash
# Validates git commands against Git safety rules.
# Blocks: force-push, pushes to protected branches, branch deletion,
#         checkout to protected branches, committing .env files.
# Runs as a PreToolUse hook for Bash tool calls.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# ============================================================================
# Git command validation
# ============================================================================

if echo "$COMMAND" | grep -q 'git '; then

  # Block git push --force
  # Use word-boundary match so branch names like "feat/...-filter-ui" don't false-positive on "-f"
  if echo "$COMMAND" | grep -qE 'git\s+push\s+.*(\s-f(\s|$)|--force)'; then
    echo '{"decision":"block","reason":"Force push is not allowed by OX E2E agent safety rules."}'
    exit 0
  fi

  # Block direct commits/pushes to protected branches — loaded from policy if available
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  POLICY_BRANCHES=$(python3 "$SCRIPT_DIR/load-policy.py" _common --field git.protected_branches 2>/dev/null)
  if [ -n "$POLICY_BRANCHES" ] && [ "$POLICY_BRANCHES" != "null" ]; then
    PROTECTED_BRANCHES=$(echo "$POLICY_BRANCHES" | python3 -c "import json,sys; print(' '.join(b for b in json.load(sys.stdin) if '*' not in b))" 2>/dev/null)
  fi
  : "${PROTECTED_BRANCHES:=developmentV2 development main master}"
  for branch in $PROTECTED_BRANCHES; do
    if echo "$COMMAND" | grep -qE "git\s+push\s+\w+\s+$branch(\s|$)"; then
      echo '{"decision":"block","reason":"Direct push to protected branch '"'$branch'"' is not allowed."}'
      exit 0
    fi
  done

  # Block pushes to release/* branches
  if echo "$COMMAND" | grep -qE 'git\s+push\s+\w+\s+release/'; then
    echo '{"decision":"block","reason":"Direct push to release branches is not allowed."}'
    exit 0
  fi

  # Block deletion of remote branches
  if echo "$COMMAND" | grep -qE 'git\s+push\s+\w+\s+(--delete|:)'; then
    echo '{"decision":"block","reason":"Deleting remote branches is not allowed."}'
    exit 0
  fi

  # Block checkout to protected branches (risks accidental commits)
  if echo "$COMMAND" | grep -qE 'git\s+checkout\s+(developmentV2|development|main|master)(\s|$)'; then
    echo '{"decision":"block","reason":"Checking out protected branch is not allowed. Create a side branch instead."}'
    exit 0
  fi

  # Block committing .env files
  if echo "$COMMAND" | grep -qE 'git\s+add\s+.*\.env'; then
    echo '{"decision":"block","reason":"Committing .env files is not allowed by OX E2E agent security rules."}'
    exit 0
  fi
fi

# ============================================================================
# GitHub CLI (gh) command validation
# ============================================================================

if echo "$COMMAND" | grep -q 'gh '; then

  # Block PR creation targeting protected branches (except developmentV2)
  if echo "$COMMAND" | grep -qE 'gh\s+pr\s+create'; then
    for branch in main master development; do
      if echo "$COMMAND" | grep -qE "(-B|--base)\s+$branch(\s|$)"; then
        echo '{"decision":"block","reason":"Creating PR targeting protected branch '"'$branch'"' is not allowed. Target developmentV2 instead."}'
        exit 0
      fi
    done
  fi

  # Block merge operations (MR reviewers handle merges)
  if echo "$COMMAND" | grep -qE 'gh\s+pr\s+merge'; then
    echo '{"decision":"block","reason":"Merging PRs is not allowed. PR reviewers handle merges."}'
    exit 0
  fi
fi

exit 0
