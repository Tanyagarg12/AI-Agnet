#!/usr/bin/env bash
# check-inbox.sh — Fetch pending commands from remote dashboard + local inbox.
# HTTP fallback for command polling when the relay daemon is not running.
#
# Usage: ./scripts/check-inbox.sh <ticket-key>
#
# Outputs a JSON array of pending commands to stdout.
# Never fails the pipeline — always exits 0, outputs [] on error.
#
# Security: Ticket key is validated. No secrets in output.

set -euo pipefail

# Ensure the script never fails the pipeline
_SCRIPT_OK=0
trap 'if [ "$_SCRIPT_OK" -eq 0 ]; then echo "[]"; fi; exit 0' ERR EXIT

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [ $# -lt 1 ]; then
    echo "[]"
    _SCRIPT_OK=1
    exit 0
fi

TICKET_KEY="$1"

# Validate ticket key format
if ! echo "${TICKET_KEY}" | grep -qE '^([A-Z]{1,10}-[0-9A-Z]{1,10}|PR-toSTG-[0-9]{4}-[0-9]{2}-[0-9]{2}[a-z]?)$'; then
    echo "[check-inbox] ERROR: Invalid ticket key format: ${TICKET_KEY}" >&2
    echo "[]"
    _SCRIPT_OK=1
    exit 0
fi

# ---------------------------------------------------------------------------
# Resolve dashboard URL
# ---------------------------------------------------------------------------
DASHBOARD_BASE_URL="${DASHBOARD_URL:-http://52.51.14.138:3459}"
DASHBOARD_BASE_URL="${DASHBOARD_BASE_URL%/}"

# ---------------------------------------------------------------------------
# Resolve ticket directory
# ---------------------------------------------------------------------------
if echo "${TICKET_KEY}" | grep -qE '^PR-toSTG-'; then
    TICKET_DIR="${PROJECT_ROOT}/memory/discovery/scans/${TICKET_KEY}"
else
    TICKET_DIR="${PROJECT_ROOT}/memory/tickets/${TICKET_KEY}"
fi

INBOX_PATH="${TICKET_DIR}/inbox.json"

# ---------------------------------------------------------------------------
# Fetch remote commands via dashboard API
# ---------------------------------------------------------------------------
REMOTE_COMMANDS="[]"

# Step 1: Look up pipeline ID
PIPELINE_RESPONSE=$(curl -s \
    --connect-timeout 5 \
    --max-time 10 \
    "${DASHBOARD_BASE_URL}/api/e2e-agent/pipelines?ticket_key=${TICKET_KEY}" 2>/dev/null) || PIPELINE_RESPONSE=""

if [ -n "${PIPELINE_RESPONSE}" ]; then
    PIPELINE_ID=$(python3 -c "
import json, sys
try:
    data = json.loads('''${PIPELINE_RESPONSE}''')
    if isinstance(data, list) and len(data) > 0:
        print(data[0].get('id', ''))
    elif isinstance(data, dict):
        print(data.get('id', ''))
    else:
        print('')
except:
    print('')
" 2>/dev/null) || PIPELINE_ID=""

    # Step 2: Fetch pending commands for this pipeline
    if [ -n "${PIPELINE_ID}" ]; then
        COMMANDS_RESPONSE=$(curl -s \
            --connect-timeout 5 \
            --max-time 10 \
            "${DASHBOARD_BASE_URL}/api/e2e-agent/pipelines/${PIPELINE_ID}/commands?status=pending" 2>/dev/null) || COMMANDS_RESPONSE=""

        if [ -n "${COMMANDS_RESPONSE}" ]; then
            REMOTE_COMMANDS=$(python3 -c "
import json, sys
try:
    data = json.loads('''${COMMANDS_RESPONSE}''')
    if isinstance(data, list):
        print(json.dumps(data))
    else:
        print('[]')
except:
    print('[]')
" 2>/dev/null) || REMOTE_COMMANDS="[]"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Read local inbox.json
# ---------------------------------------------------------------------------
LOCAL_COMMANDS="[]"
if [ -f "${INBOX_PATH}" ]; then
    LOCAL_COMMANDS=$(python3 -c "
import json, sys
try:
    with open('${INBOX_PATH}') as f:
        data = json.load(f)
    cmds = data.get('commands', [])
    if isinstance(cmds, list):
        print(json.dumps(cmds))
    else:
        print('[]')
except:
    print('[]')
" 2>/dev/null) || LOCAL_COMMANDS="[]"
fi

# ---------------------------------------------------------------------------
# Merge remote + local, dedup by command id
# ---------------------------------------------------------------------------
MERGED=$(python3 -c "
import json, sys
try:
    remote = json.loads('''${REMOTE_COMMANDS}''')
    local = json.loads('''${LOCAL_COMMANDS}''')
    seen = set()
    merged = []
    for cmd in remote + local:
        cid = cmd.get('id', '')
        if cid and cid in seen:
            continue
        if cid:
            seen.add(cid)
        merged.append(cmd)
    print(json.dumps(merged))
except:
    print('[]')
" 2>/dev/null) || MERGED="[]"

echo "${MERGED}"

_SCRIPT_OK=1
exit 0
