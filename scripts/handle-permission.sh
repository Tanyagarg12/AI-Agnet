#!/bin/bash
# handle-permission.sh — PermissionRequest hook for Claude Code.
# Receives permission request on stdin, forwards to dashboard for approval,
# returns the decision as hook output on stdout.
#
# Used by the worker daemon: Claude Code calls this hook when a tool needs
# approval. The script POSTs the request to the dashboard, polls for the
# user's decision, and returns allow/deny.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Only forward to dashboard when running in worker mode.
# In interactive terminal mode, let Claude Code prompt the user directly.
if [ "${CLAUDE_WORKER_MODE:-}" != "1" ]; then
  exit 0
fi

# Read hook input from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# If jq not available or no tool name, allow by default (don't block)
if [ -z "$TOOL_NAME" ]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
  exit 0
fi

DASHBOARD_URL="${DASHBOARD_URL:-http://52.51.14.138:3459}"
PERMISSION_ENDPOINT="$DASHBOARD_URL/api/e2e-agent/permission-request"

TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')
SUGGESTIONS=$(echo "$INPUT" | jq -c '.permission_suggestions // []')

# POST to dashboard and wait for decision
# OX Agent: SSRF not applicable — DASHBOARD_URL is from env config, not user input
RESPONSE=$(curl -s -m 120 -X POST "$PERMISSION_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{
    \"session_id\": \"$SESSION_ID\",
    \"tool_name\": \"$TOOL_NAME\",
    \"tool_input\": $TOOL_INPUT,
    \"permission_suggestions\": $SUGGESTIONS
  }" 2>/dev/null || echo '{"behavior":"allow"}')

BEHAVIOR=$(echo "$RESPONSE" | jq -r '.behavior // "allow"')
MESSAGE=$(echo "$RESPONSE" | jq -r '.message // empty')

if [ "$BEHAVIOR" = "deny" ]; then
  if [ -n "$MESSAGE" ]; then
    jq -n --arg msg "$MESSAGE" '{
      hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: {
          behavior: "deny",
          message: $msg
        }
      }
    }'
  else
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Rejected by dashboard"}}}'
  fi
else
  UPDATED_INPUT=$(echo "$RESPONSE" | jq -c '.updatedInput // empty')
  if [ -n "$UPDATED_INPUT" ] && [ "$UPDATED_INPUT" != "null" ]; then
    jq -n --argjson input "$UPDATED_INPUT" '{
      hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: {
          behavior: "allow",
          updatedInput: $input
        }
      }
    }'
  else
    echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
  fi
fi
