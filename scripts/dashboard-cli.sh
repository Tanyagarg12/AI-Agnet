#!/usr/bin/env bash
# dashboard-cli.sh — Thin wrapper around cli-anything-rfe-dashboard with fallback.
#
# Usage: ./scripts/dashboard-cli.sh e2e report OXDEV-123 triage --status completed --data '{...}'
#        ./scripts/dashboard-cli.sh agent notify OXDEV-123 --stage code-writer --type approval_needed --message "..."
#
# Resolves DASHBOARD_URL, tries the Python CLI, falls back to report-to-dashboard.sh.
# Never blocks the pipeline — errors are logged and skipped.

set -euo pipefail

_SCRIPT_OK=0
trap 'if [ "$_SCRIPT_OK" -eq 0 ]; then echo "[dashboard-cli] WARNING: Error occurred but will not block pipeline." >&2; fi; exit 0' ERR EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Resolve dashboard API URL
# ---------------------------------------------------------------------------
DASHBOARD_API_URL="${DASHBOARD_URL:-}"

# Fallback: check dashboard.config.json
if [ -z "$DASHBOARD_API_URL" ]; then
    PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    CONFIG_FILE="${PROJECT_ROOT}/dashboard.config.json"
    if [ -f "${CONFIG_FILE}" ]; then
        DASHBOARD_API_URL=$(python3 -c "
import json
try:
    with open('${CONFIG_FILE}') as f:
        print(json.load(f).get('dashboard_url', ''))
except:
    print('')
" 2>/dev/null || echo "")
    fi
fi

if [ -z "$DASHBOARD_API_URL" ]; then
    echo "[dashboard-cli] WARNING: No dashboard URL configured. Set DASHBOARD_URL env var." >&2
    exit 0
fi

# Strip trailing slash, append /api if not already present
DASHBOARD_API_URL="${DASHBOARD_API_URL%/}"
case "$DASHBOARD_API_URL" in
    */api) ;; # already has /api
    *)    DASHBOARD_API_URL="${DASHBOARD_API_URL}/api" ;;
esac

# ---------------------------------------------------------------------------
# Try the Python CLI first
# ---------------------------------------------------------------------------
# Resolve CLI command: check PATH, then Python scripts dir
CLI_CMD=""
if command -v cli-anything-rfe-dashboard &>/dev/null; then
    CLI_CMD="cli-anything-rfe-dashboard"
else
    # pip may install to a bin dir not on PATH (e.g., /Library/Frameworks/Python.framework/.../bin)
    PY_BIN=$(python3 -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>/dev/null || true)
    if [ -n "$PY_BIN" ] && [ -x "${PY_BIN}/cli-anything-rfe-dashboard" ]; then
        CLI_CMD="${PY_BIN}/cli-anything-rfe-dashboard"
    fi
fi

if [ -n "$CLI_CMD" ]; then
    echo "[dashboard-cli] Using CLI: $CLI_CMD $*" >&2
    "$CLI_CMD" --url "$DASHBOARD_API_URL" --json "$@" 2>&1 || {
        echo "[dashboard-cli] WARNING: CLI call failed. Continuing pipeline." >&2
    }
    _SCRIPT_OK=1
    exit 0
fi

# ---------------------------------------------------------------------------
# Fallback: translate to report-to-dashboard.sh for "e2e report" commands
# ---------------------------------------------------------------------------
echo "[dashboard-cli] CLI not installed. Falling back to report-to-dashboard.sh" >&2

# Parse: e2e report <ticket-key> <stage> [--status STATUS] [--data JSON] [--needs-human] ...
# The fallback only handles "e2e report" — other commands are skipped gracefully.
if [ $# -lt 4 ] || [ "$1" != "e2e" ] || [ "$2" != "report" ]; then
    echo "[dashboard-cli] Fallback only supports 'e2e report'. Skipping: $1 $2" >&2
    exit 0
fi

TICKET_KEY="$3"
STAGE="$4"
shift 4

# Forward recognized flags to report-to-dashboard.sh (ignore --data, not supported by old script)
FALLBACK_ARGS=("${TICKET_KEY}" "${STAGE}")
while [ $# -gt 0 ]; do
    case "$1" in
        --status)       FALLBACK_ARGS+=("--status" "${2:-in_progress}"); shift 2 ;;
        --needs-human)  FALLBACK_ARGS+=("--needs-human"); shift ;;
        --notification-type) FALLBACK_ARGS+=("--notification-type" "${2:-}"); shift 2 ;;
        --notification-msg)  FALLBACK_ARGS+=("--notification-msg" "${2:-}"); shift 2 ;;
        --data)         shift 2 ;; # --data is CLI-only, skip for fallback
        *)              shift ;;
    esac
done

"${SCRIPT_DIR}/report-to-dashboard.sh" "${FALLBACK_ARGS[@]}" 2>&1 || true

_SCRIPT_OK=1
exit 0
