#!/usr/bin/env bash
# jira-curl.sh — Wrapper around curl for Jira API calls with DNS fallback.
#
# Some networks have broken local DNS that can't resolve *.atlassian.net.
# This script tries a normal curl first, and if DNS fails, resolves via
# Google DNS (8.8.8.8) and uses curl --resolve to bypass local DNS.
#
# Usage:
#   ./scripts/jira-curl.sh <path> [extra-curl-args...]
#
# Example:
#   ./scripts/jira-curl.sh /rest/api/2/issue/KAN-4?fields=summary
#   ./scripts/jira-curl.sh /rest/api/2/myself
#
# Requires: JIRA_BASE_URL, JIRA_USER, JIRA_TOKEN env vars

set -euo pipefail

API_PATH="${1:?Usage: jira-curl.sh <api-path> [curl-args...]}"
shift

# Load .env if vars not set
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
if [ -z "${JIRA_BASE_URL:-}" ] && [ -f "$PROJECT_DIR/.env" ]; then
    set -a; source "$PROJECT_DIR/.env" 2>/dev/null; set +a
fi

JIRA_BASE_URL="${JIRA_BASE_URL:?JIRA_BASE_URL not set}"
JIRA_USER="${JIRA_USER:?JIRA_USER not set}"
JIRA_TOKEN="${JIRA_TOKEN:?JIRA_TOKEN not set}"

# Extract hostname from JIRA_BASE_URL
JIRA_HOST=$(echo "$JIRA_BASE_URL" | sed 's|https\?://||' | sed 's|/.*||')
FULL_URL="${JIRA_BASE_URL}${API_PATH}"

# Try 1: Normal curl (local DNS)
RESULT=$(curl -s --connect-timeout 10 --max-time 30 \
    -w "\n__HTTP_CODE__:%{http_code}" \
    -u "${JIRA_USER}:${JIRA_TOKEN}" \
    -H "Accept: application/json" \
    "$FULL_URL" "$@" 2>/dev/null) || true

HTTP_CODE=$(echo "$RESULT" | grep "__HTTP_CODE__:" | sed 's/.*__HTTP_CODE__://')
BODY=$(echo "$RESULT" | grep -v "__HTTP_CODE__:")

if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]; then
    # Normal DNS worked
    echo "$BODY"
    exit 0
fi

# Try 2: DNS failed — resolve via Google DNS and use --resolve
IP=$(nslookup "$JIRA_HOST" 8.8.8.8 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')

if [ -z "$IP" ]; then
    echo "ERROR: Cannot resolve $JIRA_HOST via any DNS" >&2
    exit 1
fi

RESULT=$(curl -s --resolve "${JIRA_HOST}:443:${IP}" \
    --connect-timeout 15 --max-time 30 \
    -w "\n__HTTP_CODE__:%{http_code}" \
    -u "${JIRA_USER}:${JIRA_TOKEN}" \
    -H "Accept: application/json" \
    "$FULL_URL" "$@" 2>/dev/null) || true

HTTP_CODE=$(echo "$RESULT" | grep "__HTTP_CODE__:" | sed 's/.*__HTTP_CODE__://')
BODY=$(echo "$RESULT" | grep -v "__HTTP_CODE__:")

if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]; then
    echo "$BODY"
    exit 0
fi

echo "ERROR: Failed to reach $JIRA_HOST (DNS and --resolve both failed)" >&2
exit 1
