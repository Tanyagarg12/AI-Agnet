#!/bin/bash
# PreToolUse hook: blocks Bash commands that would echo/print literal credential values to stdout.
# Allows playwright-cli fill commands (they legitimately need the password).
# Exit code 0 = allow, JSON with decision:block = block.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only validate Bash commands
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Allow playwright-cli fill commands (they legitimately pass credentials to form fields)
if echo "$COMMAND" | grep -qE 'playwright-cli\s+fill'; then
  exit 0
fi

# Load credential values from env vars (set via settings.local.json or .env)
STAGING_URL="${STAGING_URL:-}"
STAGING_USER="${STAGING_USER:-}"
STAGING_PASSWORD="${STAGING_PASSWORD:-}"

# If env vars are not set, skip validation (credentials not yet configured)
if [ -z "$STAGING_URL" ] && [ -z "$STAGING_USER" ] && [ -z "$STAGING_PASSWORD" ]; then
  exit 0
fi

# Check for commands that would print credential values to stdout
# Only block echo/printf/cat that output the literal value
for CRED_VALUE in "$STAGING_PASSWORD" "$STAGING_USER"; do
  [ -z "$CRED_VALUE" ] && continue

  # Check if the command contains the literal credential value
  if echo "$COMMAND" | grep -qF "$CRED_VALUE"; then
    # Allow: playwright-cli commands, grep/find (searching for leaks is ok), git commit messages
    if echo "$COMMAND" | grep -qE '^(playwright-cli|grep|find|git commit|git log)'; then
      continue
    fi
    # Block: echo, printf, cat with redirect, or any command that would print the value
    if echo "$COMMAND" | grep -qE '(echo|printf|cat\s|print)\s'; then
      echo '{"decision":"block","reason":"Command would output literal credential values to stdout. Use $STAGING_USER / $STAGING_PASSWORD env vars in playwright-cli fill commands instead of printing them."}'
      exit 0
    fi
  fi
done

exit 0
