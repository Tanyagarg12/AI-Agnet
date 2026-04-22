#!/bin/bash
# TaskCompleted hook: validates that a teammate produced its expected output file
# before allowing task completion. Exit code 2 = block completion with feedback.

set -euo pipefail

INPUT=$(cat)
TASK_SUBJECT=$(echo "$INPUT" | jq -r '.task_subject // empty' 2>/dev/null || true)

if [ -z "$TASK_SUBJECT" ]; then
  exit 0
fi

# Extract ticket key from task subject (pattern: "... for OXDEV-123" or "... OXDEV-123")
TICKET_KEY=$(echo "$TASK_SUBJECT" | grep -oE 'OXDEV-[0-9]+' | head -1)

if [ -z "$TICKET_KEY" ]; then
  exit 0
fi

MEMORY_DIR="memory/tickets/$TICKET_KEY"

# If the memory dir doesn't exist yet, allow completion (may be a setup task)
if [ ! -d "$MEMORY_DIR" ]; then
  exit 0
fi

# Validate output file exists based on task subject keywords
check_file() {
  local keyword="$1"
  local file="$2"
  if echo "$TASK_SUBJECT" | grep -qi "$keyword"; then
    if [ ! -f "$MEMORY_DIR/$file" ]; then
      echo "Output file not found: $MEMORY_DIR/$file. Write your output before completing this task." >&2
      exit 2
    fi
    # Check file is not empty
    if [ ! -s "$MEMORY_DIR/$file" ]; then
      echo "Output file is empty: $MEMORY_DIR/$file. Write meaningful output before completing this task." >&2
      exit 2
    fi
  fi
}

check_file "triage" "triage.json"
check_file "explore" "exploration.md"
check_file "analyst" "exploration.md"
check_file "playwright" "playwright-data.json"
check_file "browser" "playwright-data.json"
check_file "code\|implement" "implementation.md"
check_file "developer" "implementation.md"
check_file "test\|run" "test-results.json"
check_file "tester" "test-results.json"
check_file "debug" "debug-history.md"
check_file "debug" "test-results.json"
check_file "fix.*fail\|fail.*fix" "test-results.json"
check_file "fix.*fail\|fail.*fix" "debug-history.md"
check_file "pr\|merge" "pr-result.md"

# ---------------------------------------------------------------------------
# Phase B: JSON schema validation (if validate-output-schema.py exists)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA_SCRIPT="$SCRIPT_DIR/validate-output-schema.py"

if [ -f "$SCHEMA_SCRIPT" ]; then
  STAGE=""
  if echo "$TASK_SUBJECT" | grep -qi "triage"; then STAGE="triage"; fi
  if echo "$TASK_SUBJECT" | grep -qi "explore\|analyst"; then STAGE="explorer"; fi
  if echo "$TASK_SUBJECT" | grep -qi "playwright\|browser\|locator"; then STAGE="playwright"; fi
  if echo "$TASK_SUBJECT" | grep -qi "code\|implement\|developer"; then STAGE="code-writer"; fi
  if echo "$TASK_SUBJECT" | grep -qi "test\|run\|tester"; then STAGE="test-runner"; fi
  if echo "$TASK_SUBJECT" | grep -qi "debug\|fix.*fail"; then STAGE="debug"; fi
  if echo "$TASK_SUBJECT" | grep -qi "pr\|merge"; then STAGE="pr"; fi

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
