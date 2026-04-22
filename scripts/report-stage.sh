#!/usr/bin/env bash
# report-stage.sh — Lightweight stage reporter via relay (WS) with HTTP fallback.
#
# Usage: report-stage.sh <ticket-key> <stage> [--status STATUS] [--needs-human] [--notification-type TYPE] [--notification-msg MSG]
#
# Writes a stage-report-*.json signal file that the relay daemon picks up and sends
# via WebSocket to the dashboard. Falls back to report-to-dashboard.sh if relay isn't running.
#
# This is MUCH faster than report-to-dashboard.sh (no Python, no file parsing, no curl).
# Use for stage transitions. Use report-to-dashboard.sh for completion reports that need
# full stage_data extraction (test results, diffs, etc.).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ $# -lt 2 ]; then
    echo "[report-stage] Usage: $0 <ticket-key> <stage> [options]" >&2
    exit 0
fi

TICKET_KEY="$1"
STAGE="$2"
shift 2

STATUS="in_progress"
NEEDS_HUMAN="false"
NOTIFICATION_TYPE=""
NOTIFICATION_MSG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --status) STATUS="${2:-in_progress}"; shift 2 ;;
        --needs-human) NEEDS_HUMAN="true"; shift ;;
        --notification-type) NOTIFICATION_TYPE="${2:-}"; shift 2 ;;
        --notification-msg) NOTIFICATION_MSG="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done

# Determine ticket directory
TICKET_DIR="${PROJECT_ROOT}/memory/tickets/${TICKET_KEY}"
if echo "${TICKET_KEY}" | grep -qE '^PR-toSTG-'; then
    TICKET_DIR="${PROJECT_ROOT}/memory/discovery/scans/${TICKET_KEY}"
fi

# Build the signal file
REPORT_FILE="${TICKET_DIR}/stage-report-$(date +%s%N).json"

mkdir -p "${TICKET_DIR}"

NOTIFICATION_JSON="null"
if [ "${NEEDS_HUMAN}" = "true" ]; then
    NOTIFICATION_JSON="{\"type\":\"${NOTIFICATION_TYPE}\",\"message\":\"${NOTIFICATION_MSG}\"}"
fi

cat > "${REPORT_FILE}" << EOF
{
    "stage": "${STAGE}",
    "status": "${STATUS}",
    "ticket_key": "${TICKET_KEY}",
    "needs_human": ${NEEDS_HUMAN},
    "notification": ${NOTIFICATION_JSON},
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# Check if relay is running (PID file exists and process alive)
RELAY_PID_FILE="${TICKET_DIR}/relay.pid"
RELAY_RUNNING=false
if [ -f "${RELAY_PID_FILE}" ]; then
    RELAY_PID=$(cat "${RELAY_PID_FILE}" 2>/dev/null)
    if [ -n "${RELAY_PID}" ] && kill -0 "${RELAY_PID}" 2>/dev/null; then
        RELAY_RUNNING=true
    fi
fi

if [ "${RELAY_RUNNING}" = true ]; then
    # Relay will pick up the signal file via fs.watch — give it a moment
    echo "[report-stage] Signal file written for relay: ${STAGE} ${STATUS}" >&2
else
    # Fallback: relay not running, use HTTP report-to-dashboard.sh
    echo "[report-stage] Relay not running, falling back to HTTP" >&2
    rm -f "${REPORT_FILE}" 2>/dev/null || true
    ARGS=("${TICKET_KEY}" "${STAGE}" "--status" "${STATUS}")
    [ "${NEEDS_HUMAN}" = "true" ] && ARGS+=("--needs-human")
    [ -n "${NOTIFICATION_TYPE}" ] && ARGS+=("--notification-type" "${NOTIFICATION_TYPE}")
    [ -n "${NOTIFICATION_MSG}" ] && ARGS+=("--notification-msg" "${NOTIFICATION_MSG}")
    "${SCRIPT_DIR}/report-to-dashboard.sh" "${ARGS[@]}" 2>&1 || true
fi

exit 0
