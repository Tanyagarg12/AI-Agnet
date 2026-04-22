#!/bin/bash
# Validates that protected framework files are not being modified.
# Blocks: edits to setHooks.js, setHooksAPI.js, playwright.config.js,
#         global.json, generateAccessToken.js.
# Runs as a PreToolUse hook for Bash and Edit/Write tool calls.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Protected files (basenames) — loaded from policy if available, else hardcoded fallback
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POLICY_PROTECTED=$(python3 "$SCRIPT_DIR/load-policy.py" _common --field filesystem.never_modify 2>/dev/null)
if [ -n "$POLICY_PROTECTED" ] && [ "$POLICY_PROTECTED" != "null" ]; then
  PROTECTED_FILES=$(echo "$POLICY_PROTECTED" | python3 -c "import json,sys,os; print(' '.join(os.path.basename(f) for f in json.load(sys.stdin)))" 2>/dev/null)
fi
: "${PROTECTED_FILES:=setHooks.js setHooksAPI.js playwright.config.js global.json generateAccessToken.js}"

# ============================================================================
# Check Edit/Write tool calls by file_path
# ============================================================================

if [ -n "$FILE_PATH" ]; then
  BASENAME=$(basename "$FILE_PATH")
  for protected in $PROTECTED_FILES; do
    if [ "$BASENAME" = "$protected" ]; then
      echo '{"decision":"block","reason":"Modifying '"$protected"' is not allowed by OX E2E framework safety rules. This file is critical infrastructure that affects all tests."}'
      exit 0
    fi
  done
fi

# ============================================================================
# Check Bash tool calls for commands that target protected files
# ============================================================================

if [ -n "$COMMAND" ]; then
  for protected in $PROTECTED_FILES; do
    # Check for write/edit/sed/awk/tee/cp/mv commands targeting protected files
    if echo "$COMMAND" | grep -qE "(sed|awk|tee|cp|mv|cat\s*>|echo\s*>|printf\s*>)\s" && echo "$COMMAND" | grep -q "$protected"; then
      echo '{"decision":"block","reason":"Modifying '"$protected"' via shell command is not allowed by OX E2E framework safety rules."}'
      exit 0
    fi

    # Check for git checkout of protected files (reverting changes)
    if echo "$COMMAND" | grep -qE 'git\s+checkout\s' && echo "$COMMAND" | grep -q "$protected"; then
      echo '{"decision":"block","reason":"Reverting '"$protected"' via git checkout is not allowed by OX E2E framework safety rules."}'
      exit 0
    fi

    # Check for rm commands targeting protected files
    if echo "$COMMAND" | grep -qE '(rm|unlink)\s' && echo "$COMMAND" | grep -q "$protected"; then
      echo '{"decision":"block","reason":"Deleting '"$protected"' is not allowed by OX E2E framework safety rules."}'
      exit 0
    fi
  done
fi

exit 0
