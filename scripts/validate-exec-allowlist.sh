#!/bin/bash
# PreToolUse hook: enforces per-agent command allowlists from policy files.
# Each agent declares exec.allow_patterns (glob) and exec.deny_patterns (glob).
# Deny patterns take precedence over allow patterns.
# Falls back to allow-all if policy loading fails (graceful degradation).
#
# Inspired by OpenClaw's exec-approvals system.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only validate Bash commands
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Determine agent name from environment or teammate context
# Claude Code sets CLAUDE_AGENT_NAME for teammates; fall back to "lead"
AGENT_NAME="${CLAUDE_AGENT_NAME:-lead}"

# Map common teammate names to agent policy names
case "$AGENT_NAME" in
  scanner-*)          POLICY_NAME="scanner-agent" ;;
  analyst|explorer)   POLICY_NAME="explorer-agent" ;;
  browser|playwright) POLICY_NAME="playwright-agent" ;;
  developer)          POLICY_NAME="code-writer-agent" ;;
  tester|test-runner) POLICY_NAME="test-runner-agent" ;;
  validator)          POLICY_NAME="validator-agent" ;;
  retrospective)      POLICY_NAME="retrospective-agent" ;;
  lead|*)             POLICY_NAME="" ;;  # Lead agent: no exec restrictions
esac

# Lead agent is unrestricted
if [ -z "$POLICY_NAME" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load deny patterns — block these commands regardless of allow
DENY_JSON=$(python3 "$SCRIPT_DIR/load-policy.py" "$POLICY_NAME" --field exec.deny_patterns 2>/dev/null)
if [ -n "$DENY_JSON" ] && [ "$DENY_JSON" != "null" ]; then
  # Check each deny pattern against the command
  DENIED=$(python3 -c "
import json, sys, fnmatch
patterns = json.loads('$DENY_JSON')
cmd = '''$COMMAND'''
for p in patterns:
    if fnmatch.fnmatch(cmd, p) or fnmatch.fnmatch(cmd.split()[0] if cmd.split() else '', p):
        print(p)
        sys.exit(0)
" 2>/dev/null)

  if [ -n "$DENIED" ]; then
    echo "{\"decision\":\"block\",\"reason\":\"Command denied by exec policy for $POLICY_NAME. Matched deny pattern: $DENIED\"}"
    exit 0
  fi
fi

# Load allow patterns — if defined, only matching commands are permitted
ALLOW_JSON=$(python3 "$SCRIPT_DIR/load-policy.py" "$POLICY_NAME" --field exec.allow_patterns 2>/dev/null)
if [ -n "$ALLOW_JSON" ] && [ "$ALLOW_JSON" != "null" ]; then
  ALLOWED=$(python3 -c "
import json, sys, fnmatch
patterns = json.loads('$ALLOW_JSON')
cmd = '''$COMMAND'''
for p in patterns:
    if fnmatch.fnmatch(cmd, p):
        sys.exit(0)
# Also check if command starts with an allowed binary
first_word = cmd.split()[0] if cmd.split() else ''
for p in patterns:
    if fnmatch.fnmatch(first_word, p.split()[0] if ' ' in p else p):
        sys.exit(0)
print('no_match')
" 2>/dev/null)

  if [ "$ALLOWED" = "no_match" ]; then
    # Extract first word of command for clearer error
    CMD_BIN=$(echo "$COMMAND" | awk '{print $1}')
    echo "{\"decision\":\"block\",\"reason\":\"Command '$CMD_BIN ...' not in exec allowlist for $POLICY_NAME. Add it to exec.allow_patterns in .claude/policies/$POLICY_NAME.json\"}"
    exit 0
  fi
fi

# If no allow_patterns defined, or policy loading failed: allow through
exit 0
