#!/usr/bin/env bash
# gp-detect-platform.sh
# Auto-detects the ticket platform from a URL or key format.
# Usage: ./scripts/gp-detect-platform.sh "<ticket_input>" [override]
# Outputs: platform_id (e.g., jira-any, github-issues, azure-devops, linear, servicenow)

set -euo pipefail

TICKET_INPUT="${1:-}"
OVERRIDE="${2:-}"

if [ -n "${OVERRIDE}" ]; then
    echo "${OVERRIDE}"
    exit 0
fi

if [ -z "${TICKET_INPUT}" ]; then
    echo "ERROR: No ticket input provided" >&2
    exit 1
fi

# URL-based detection
if echo "${TICKET_INPUT}" | grep -qiE 'atlassian\.net/browse/'; then
    echo "jira-any"
    exit 0
fi

if echo "${TICKET_INPUT}" | grep -qiE 'dev\.azure\.com|visualstudio\.com/_workitems'; then
    echo "azure-devops"
    exit 0
fi

if echo "${TICKET_INPUT}" | grep -qiE 'github\.com/.*/issues/[0-9]+'; then
    echo "github-issues"
    exit 0
fi

if echo "${TICKET_INPUT}" | grep -qiE 'linear\.app/.*/issue/'; then
    echo "linear"
    exit 0
fi

if echo "${TICKET_INPUT}" | grep -qiE 'service-now\.com'; then
    echo "servicenow"
    exit 0
fi

# Key-format based detection (when just a key is provided, no URL)
# Jira: PROJECT-123 (all caps project key, dash, number)
if echo "${TICKET_INPUT}" | grep -qE '^[A-Z][A-Z0-9]+-[0-9]+$'; then
    echo "jira-any"
    exit 0
fi

# GitHub issue: #123 or just a number
if echo "${TICKET_INPUT}" | grep -qE '^#?[0-9]+$'; then
    # Check if GH_REPO is set and non-empty
    if [ -n "${GH_REPO:-}" ]; then
        echo "github-issues"
        exit 0
    fi
    # If JIRA_BASE_URL is set, could be a ServiceNow number
    if [ -n "${SNOW_INSTANCE:-}" ]; then
        echo "servicenow"
        exit 0
    fi
fi

# Azure DevOps work item: just a number
if echo "${TICKET_INPUT}" | grep -qE '^[0-9]+$'; then
    if [ -n "${ADO_ORG:-}" ]; then
        echo "azure-devops"
        exit 0
    fi
fi

# ServiceNow: INC, CHG, RITM, US, SCTASK prefix
if echo "${TICKET_INPUT}" | grep -qiE '^(INC|CHG|RITM|US|SCTASK)[0-9]+$'; then
    echo "servicenow"
    exit 0
fi

# Fallback: check defaults config
DEFAULT=$(python3 -c "
import json
try:
    with open('config/gp-defaults.json') as f:
        print(json.load(f).get('default_platform', 'jira-any'))
except:
    print('jira-any')
" 2>/dev/null || echo "jira-any")

echo "${DEFAULT}"
