#!/bin/bash
# PreToolUse hook: detects repetitive tool-call patterns that waste agent turns.
# Tracks recent Bash commands in a sliding window and blocks when:
#   1. Same exact command repeated > threshold times (stuck loop)
#   2. Alternating between 2 commands (ping-pong pattern)
#
# State stored in /tmp/claude-loop-detect-<session>.jsonl (one JSON line per call).
# Inspired by OpenClaw's tool-loop detection system.
#
# Configuration (from _common.json exec.loop_detection):
#   history_size: 30      — sliding window of recent calls
#   repeat_threshold: 6   — block after N identical consecutive calls
#   pingpong_threshold: 8 — block after N alternating A-B-A-B calls

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only track Bash commands
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Skip short/trivial commands that are legitimately repeated (polling, status checks)
# Sleep and wait loops are expected patterns
if echo "$COMMAND" | grep -qE '^\s*(sleep|wait|echo "Waiting)'; then
  exit 0
fi

# Use session-scoped state file (CLAUDE_SESSION_ID if available, else PID-based)
SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
STATE_FILE="/tmp/claude-loop-detect-${SESSION_ID}.jsonl"

# Load thresholds from policy (with defaults)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPEAT_THRESHOLD=6
PINGPONG_THRESHOLD=8
HISTORY_SIZE=30

POLICY_LD=$(python3 "$SCRIPT_DIR/load-policy.py" _common --field exec.loop_detection 2>/dev/null)
if [ -n "$POLICY_LD" ] && [ "$POLICY_LD" != "null" ]; then
  REPEAT_THRESHOLD=$(echo "$POLICY_LD" | python3 -c "import json,sys; print(json.load(sys.stdin).get('repeat_threshold', 6))" 2>/dev/null || echo 6)
  PINGPONG_THRESHOLD=$(echo "$POLICY_LD" | python3 -c "import json,sys; print(json.load(sys.stdin).get('pingpong_threshold', 8))" 2>/dev/null || echo 8)
  HISTORY_SIZE=$(echo "$POLICY_LD" | python3 -c "import json,sys; print(json.load(sys.stdin).get('history_size', 30))" 2>/dev/null || echo 30)
fi

# Normalize command for comparison (collapse whitespace, trim)
NORM_CMD=$(echo "$COMMAND" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')

# Append current command to state file
echo "{\"cmd\":$(echo "$NORM_CMD" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo "\"$NORM_CMD\""),\"ts\":$(date +%s)}" >> "$STATE_FILE" 2>/dev/null

# Trim state file to history_size (keep last N lines)
if [ -f "$STATE_FILE" ]; then
  LINE_COUNT=$(wc -l < "$STATE_FILE" 2>/dev/null || echo 0)
  if [ "$LINE_COUNT" -gt "$HISTORY_SIZE" ]; then
    TAIL_N=$((HISTORY_SIZE))
    tail -n "$TAIL_N" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  fi
fi

# Detect patterns using Python (more reliable than bash for JSON parsing)
DETECTION=$(python3 -c "
import json, sys

state_file = '$STATE_FILE'
repeat_threshold = int('$REPEAT_THRESHOLD')
pingpong_threshold = int('$PINGPONG_THRESHOLD')

try:
    with open(state_file) as f:
        lines = f.readlines()
except:
    sys.exit(0)

cmds = []
for line in lines:
    try:
        cmds.append(json.loads(line.strip())['cmd'])
    except:
        pass

if len(cmds) < 3:
    sys.exit(0)

# Detection 1: consecutive identical commands
streak = 1
for i in range(len(cmds)-2, -1, -1):
    if cmds[i] == cmds[-1]:
        streak += 1
    else:
        break

if streak >= repeat_threshold:
    short = cmds[-1][:80] + ('...' if len(cmds[-1]) > 80 else '')
    print(json.dumps({
        'pattern': 'repeat',
        'count': streak,
        'command': short
    }))
    sys.exit(0)

# Detection 2: ping-pong (A-B-A-B alternation)
if len(cmds) >= 4:
    a = cmds[-2]
    b = cmds[-1]
    if a != b:
        pong_count = 0
        for i in range(len(cmds)-1, -1, -2):
            if i >= 1 and cmds[i] == b and cmds[i-1] == a:
                pong_count += 1
            else:
                break
        if pong_count * 2 >= pingpong_threshold:
            short_a = a[:60] + ('...' if len(a) > 60 else '')
            short_b = b[:60] + ('...' if len(b) > 60 else '')
            print(json.dumps({
                'pattern': 'pingpong',
                'count': pong_count * 2,
                'commands': [short_a, short_b]
            }))
            sys.exit(0)

sys.exit(0)
" 2>/dev/null)

# If detection found a pattern, block with feedback
if [ -n "$DETECTION" ]; then
  PATTERN=$(echo "$DETECTION" | python3 -c "import json,sys; print(json.load(sys.stdin).get('pattern',''))" 2>/dev/null)
  COUNT=$(echo "$DETECTION" | python3 -c "import json,sys; print(json.load(sys.stdin).get('count',0))" 2>/dev/null)

  case "$PATTERN" in
    repeat)
      CMD_SHORT=$(echo "$DETECTION" | python3 -c "import json,sys; print(json.load(sys.stdin).get('command',''))" 2>/dev/null)
      echo "{\"decision\":\"block\",\"reason\":\"Loop detected: you've run the same command $COUNT times consecutively ('$CMD_SHORT'). You appear stuck — try a different approach or check if the previous output already has what you need.\"}"
      # Clear state to allow recovery after agent adjusts
      > "$STATE_FILE"
      exit 0
      ;;
    pingpong)
      echo "{\"decision\":\"block\",\"reason\":\"Ping-pong loop detected: you've been alternating between 2 commands $COUNT times. You appear stuck — try a different approach.\"}"
      > "$STATE_FILE"
      exit 0
      ;;
  esac
fi

exit 0
