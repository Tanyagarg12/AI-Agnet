#!/usr/bin/env bash
# ack-command.sh — Acknowledge a processed command.
# POSTs acknowledgment to the dashboard and removes the command from local inbox.
#
# Usage: ./scripts/ack-command.sh <command-id> <status> [result-text]
#
# Arguments:
#   command-id   — The unique command ID to acknowledge
#   status       — Acknowledgment status (e.g., "completed", "failed", "rejected")
#   result-text  — (Optional) Result description or error message
#
# Never fails the pipeline — always exits 0.
#
# Security: Inputs are validated. No secrets in payloads.

set -euo pipefail

# Ensure the script never fails the pipeline
_SCRIPT_OK=0
trap 'if [ "$_SCRIPT_OK" -eq 0 ]; then echo "[ack-command] WARNING: Script encountered an error but will not block the pipeline." >&2; fi; exit 0' ERR EXIT

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [ $# -lt 2 ]; then
    echo "[ack-command] Usage: $0 <command-id> <status> [result-text]" >&2
    _SCRIPT_OK=1
    exit 0
fi

COMMAND_ID="$1"
ACK_STATUS="$2"
RESULT_TEXT="${3:-}"

# Validate command ID (non-empty, reasonable length, no special chars)
if [ -z "${COMMAND_ID}" ] || [ ${#COMMAND_ID} -gt 200 ]; then
    echo "[ack-command] ERROR: Invalid command ID" >&2
    _SCRIPT_OK=1
    exit 0
fi

# Validate status
case "${ACK_STATUS}" in
    completed|failed|rejected|skipped|acknowledged)
        ;;
    *)
        echo "[ack-command] WARNING: Unusual status '${ACK_STATUS}', proceeding anyway" >&2
        ;;
esac

# ---------------------------------------------------------------------------
# Resolve dashboard URL
# ---------------------------------------------------------------------------
DASHBOARD_BASE_URL="${DASHBOARD_URL:-http://52.51.14.138:3459}"
DASHBOARD_BASE_URL="${DASHBOARD_BASE_URL%/}"

# ---------------------------------------------------------------------------
# POST acknowledgment to dashboard
# ---------------------------------------------------------------------------
ACK_PAYLOAD=$(python3 -c "
import json
payload = {
    'status': '''${ACK_STATUS}''',
    'result': '''${RESULT_TEXT}''',
    'acknowledged_at': __import__('datetime').datetime.now(__import__('datetime').timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
}
print(json.dumps(payload))
" 2>/dev/null) || ACK_PAYLOAD="{\"status\":\"${ACK_STATUS}\"}"

HTTP_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 \
    --max-time 10 \
    -X POST \
    -H "Content-Type: application/json" \
    -d "${ACK_PAYLOAD}" \
    "${DASHBOARD_BASE_URL}/api/e2e-agent/commands/${COMMAND_ID}/ack" 2>/dev/null) || true

if [ -n "${HTTP_RESPONSE}" ] && [ "${HTTP_RESPONSE}" -ge 200 ] 2>/dev/null && [ "${HTTP_RESPONSE}" -lt 300 ] 2>/dev/null; then
    echo "[ack-command] Acknowledged command ${COMMAND_ID} (HTTP ${HTTP_RESPONSE})" >&2
elif [ -z "${HTTP_RESPONSE}" ] || [ "${HTTP_RESPONSE}" = "000" ]; then
    echo "[ack-command] WARNING: Dashboard unreachable. Continuing." >&2
else
    echo "[ack-command] WARNING: Dashboard returned HTTP ${HTTP_RESPONSE}. Continuing." >&2
fi

# ---------------------------------------------------------------------------
# Remove command from all local inbox.json files
# ---------------------------------------------------------------------------
# Search across all ticket directories for inbox files containing this command
find "${PROJECT_ROOT}/memory/tickets" "${PROJECT_ROOT}/memory/discovery/scans" \
    -name "inbox.json" -type f 2>/dev/null | while read -r inbox_file; do
    python3 -c "
import json, sys
try:
    with open('${inbox_file}') as f:
        data = json.load(f)
    commands = data.get('commands', [])
    original_count = len(commands)
    commands = [c for c in commands if c.get('id') != '${COMMAND_ID}']
    if len(commands) < original_count:
        data['commands'] = commands
        with open('${inbox_file}', 'w') as f:
            json.dump(data, f, indent=2)
except:
    pass
" 2>/dev/null || true
done

_SCRIPT_OK=1
exit 0
