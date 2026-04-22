#!/usr/bin/env bash
# validate-credentials.sh
# Validates API tokens and credentials by making lightweight API calls.
# Returns JSON: {"provider": "...", "valid": true/false, "message": "..."}
#
# Usage:
#   ./scripts/validate-credentials.sh jira
#   ./scripts/validate-credentials.sh github
#   ./scripts/validate-credentials.sh gitlab
#   ./scripts/validate-credentials.sh azure-devops
#   ./scripts/validate-credentials.sh linear
#   ./scripts/validate-credentials.sh all

set -euo pipefail

PROVIDER="${1:-all}"

json_result() {
    local provider="$1" valid="$2" message="$3"
    printf '{"provider":"%s","valid":%s,"message":"%s"}\n' "$provider" "$valid" "$message"
}

validate_jira() {
    local base_url="${JIRA_BASE_URL:-}"
    local user="${JIRA_USER:-}"
    local token="${JIRA_TOKEN:-}"

    if [ -z "$base_url" ] || [ -z "$user" ] || [ -z "$token" ]; then
        json_result "jira" "false" "Missing JIRA_BASE_URL, JIRA_USER, or JIRA_TOKEN"
        return
    fi

    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" \
        -u "${user}:${token}" \
        -H "Accept: application/json" \
        "${base_url}/rest/api/2/myself" 2>/dev/null) || status="000"

    if [ "$status" = "200" ]; then
        json_result "jira" "true" "Authenticated as ${user}"
    elif [ "$status" = "401" ] || [ "$status" = "403" ]; then
        json_result "jira" "false" "Authentication failed (HTTP ${status})"
    else
        json_result "jira" "false" "Connection failed (HTTP ${status})"
    fi
}

validate_github() {
    local token="${GH_TOKEN:-}"

    if [ -z "$token" ]; then
        json_result "github" "false" "Missing GH_TOKEN"
        return
    fi

    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/user" 2>/dev/null) || status="000"

    if [ "$status" = "200" ]; then
        local username
        username=$(curl -sf \
            -H "Authorization: Bearer ${token}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/user" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('login','unknown'))" 2>/dev/null) || username="unknown"
        json_result "github" "true" "Authenticated as ${username}"
    elif [ "$status" = "401" ]; then
        json_result "github" "false" "Invalid token (HTTP 401)"
    else
        json_result "github" "false" "Connection failed (HTTP ${status})"
    fi
}

validate_gitlab() {
    local token="${GITLAB_TOKEN:-${GITLAB_PERSONAL_ACCESS_TOKEN:-}}"
    local api_url="${GITLAB_API_URL:-https://gitlab.com/api/v4}"

    if [ -z "$token" ]; then
        json_result "gitlab" "false" "Missing GITLAB_TOKEN"
        return
    fi

    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" \
        -H "PRIVATE-TOKEN: ${token}" \
        "${api_url}/user" 2>/dev/null) || status="000"

    if [ "$status" = "200" ]; then
        local username
        username=$(curl -sf \
            -H "PRIVATE-TOKEN: ${token}" \
            "${api_url}/user" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('username','unknown'))" 2>/dev/null) || username="unknown"
        json_result "gitlab" "true" "Authenticated as ${username}"
    elif [ "$status" = "401" ]; then
        json_result "gitlab" "false" "Invalid token (HTTP 401)"
    else
        json_result "gitlab" "false" "Connection failed (HTTP ${status})"
    fi
}

validate_azure_devops() {
    local org="${ADO_ORG:-}"
    local pat="${ADO_PAT:-}"

    if [ -z "$org" ] || [ -z "$pat" ]; then
        json_result "azure-devops" "false" "Missing ADO_ORG or ADO_PAT"
        return
    fi

    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" \
        -u ":${pat}" \
        "${org}/_apis/projects?api-version=7.0&\$top=1" 2>/dev/null) || status="000"

    if [ "$status" = "200" ]; then
        json_result "azure-devops" "true" "Connected to ${org}"
    elif [ "$status" = "401" ] || [ "$status" = "203" ]; then
        json_result "azure-devops" "false" "Authentication failed (HTTP ${status})"
    else
        json_result "azure-devops" "false" "Connection failed (HTTP ${status})"
    fi
}

validate_linear() {
    local key="${LINEAR_API_KEY:-}"

    if [ -z "$key" ]; then
        json_result "linear" "false" "Missing LINEAR_API_KEY"
        return
    fi

    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: ${key}" \
        -H "Content-Type: application/json" \
        -d '{"query":"{ viewer { id name } }"}' \
        "https://api.linear.app/graphql" 2>/dev/null) || status="000"

    if [ "$status" = "200" ]; then
        json_result "linear" "true" "Connected to Linear"
    elif [ "$status" = "401" ]; then
        json_result "linear" "false" "Invalid API key (HTTP 401)"
    else
        json_result "linear" "false" "Connection failed (HTTP ${status})"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "$PROVIDER" in
    jira)          validate_jira ;;
    github)        validate_github ;;
    gitlab)        validate_gitlab ;;
    azure-devops)  validate_azure_devops ;;
    linear)        validate_linear ;;
    all)
        validate_jira
        validate_github
        validate_gitlab
        validate_azure_devops
        validate_linear
        ;;
    *)
        echo "Unknown provider: $PROVIDER" >&2
        echo "Usage: $0 {jira|github|gitlab|azure-devops|linear|all}" >&2
        exit 1
        ;;
esac
