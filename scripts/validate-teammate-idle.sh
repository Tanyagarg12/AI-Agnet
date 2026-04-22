#!/bin/bash
# TeammateIdle hook: ensures teammates have committed changes AND written output files
# before going idle. Exit code 2 = send feedback and keep teammate working.

set -euo pipefail

INPUT=$(cat)
TEAMMATE_NAME=$(echo "$INPUT" | jq -r '.teammate_name // empty' 2>/dev/null || true)
TEAMMATE_PROMPT=$(echo "$INPUT" | jq -r '.teammate_prompt // empty' 2>/dev/null || true)

# Extract ticket key from the teammate prompt
TICKET_KEY=$(echo "$TEAMMATE_PROMPT" | grep -oE 'OXDEV-[0-9]+' | head -1)

# ---------------------------------------------------------------------------
# 1. Commit discipline for code-writing teammates
# ---------------------------------------------------------------------------
case "$TEAMMATE_NAME" in
  developer|browser|code-writer|playwright)
    UNCOMMITTED=$(git status --porcelain 2>/dev/null | head -10)
    if [ -n "$UNCOMMITTED" ]; then
      echo "You have uncommitted changes. Per commit discipline rules, commit all code changes before going idle:" >&2
      echo "$UNCOMMITTED" >&2
      exit 2
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# 2. Output file checks — ensure each teammate wrote its required output
# ---------------------------------------------------------------------------
if [ -z "$TICKET_KEY" ]; then
  exit 0
fi

MEMORY_DIR="memory/tickets/$TICKET_KEY"

if [ ! -d "$MEMORY_DIR" ]; then
  exit 0
fi

check_output() {
  local file="$1"
  local label="$2"
  if [ ! -f "$MEMORY_DIR/$file" ] || [ ! -s "$MEMORY_DIR/$file" ]; then
    echo "MANDATORY OUTPUT MISSING: $MEMORY_DIR/$file is missing or empty. You MUST write $label before stopping. Write it NOW with whatever data you have." >&2
    exit 2
  fi
}

case "$TEAMMATE_NAME" in
  analyst|explorer)
    check_output "exploration.md" "exploration.md (framework patterns and findings)"
    ;;
  browser|playwright)
    check_output "playwright-data.json" "playwright-data.json (locators and page data)"
    ;;
  developer)
    # Developer teammate is used for code-writer and debug phases
    # Detect debug phase by keywords in prompt
    if echo "$TEAMMATE_PROMPT" | grep -qi "debug\|test results\|if tests fail"; then
      # Debug agent: must have debug-history.md (test-results.json is written by test-runner)
      check_output "debug-history.md" "debug-history.md (debug cycle details or 'no debug needed')"
    else
      check_output "implementation.md" "implementation.md (files created and branch info)"
    fi
    ;;
  tester|test-runner)
    check_output "test-results.json" "test-results.json (test execution results)"
    ;;
esac

# ---------------------------------------------------------------------------
# 3. Schema validation for output files (Phase B)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA_SCRIPT="$SCRIPT_DIR/validate-output-schema.py"

if [ -f "$SCHEMA_SCRIPT" ]; then
  STAGE=""
  case "$TEAMMATE_NAME" in
    analyst|explorer) STAGE="explorer" ;;
    browser|playwright) STAGE="playwright" ;;
    developer)
      if echo "$TEAMMATE_PROMPT" | grep -qi "debug\|test results\|if tests fail"; then
        STAGE="debug"
      else
        STAGE="code-writer"
      fi
      ;;
    tester|test-runner) STAGE="test-runner" ;;
  esac

  if [ -n "$STAGE" ]; then
    RESULT=$(python3 "$SCHEMA_SCRIPT" "$TICKET_KEY" "$STAGE" 2>/dev/null || echo '{"valid":true}')
    VALID=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('valid',True))" 2>/dev/null || echo "True")
    if [ "$VALID" = "False" ]; then
      ERRORS=$(echo "$RESULT" | python3 -c "import json,sys; print('\n'.join(json.load(sys.stdin).get('errors',[])))" 2>/dev/null || echo "unknown error")
      echo "Output schema validation failed for $STAGE:" >&2
      echo "$ERRORS" >&2
      exit 2
    fi
  fi
fi

exit 0
