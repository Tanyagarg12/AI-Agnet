#!/usr/bin/env bash
# gp-create-pr.sh
# VCS-agnostic PR/MR creation dispatcher.
# Usage: ./scripts/gp-create-pr.sh <vcs_id> <title> <body_file> <target_branch>
# Outputs: PR/MR URL to stdout

set -uo pipefail

VCS_ID="${1:?VCS_ID required}"
PR_TITLE="${2:?PR_TITLE required}"
BODY_FILE="${3:?BODY_FILE required}"
TARGET_BRANCH="${4:?TARGET_BRANCH required}"

if [ ! -f "${BODY_FILE}" ]; then
    echo "ERROR: Body file not found: ${BODY_FILE}" >&2
    exit 1
fi

PR_BODY=$(cat "${BODY_FILE}")

case "${VCS_ID}" in
    github)
        # Requires: GH_TOKEN, GH_REPO
        if [ -z "${GH_TOKEN:-}" ] || [ -z "${GH_REPO:-}" ]; then
            echo "ERROR: GH_TOKEN and GH_REPO must be set for GitHub PRs" >&2
            exit 1
        fi
        PR_URL=$(gh pr create \
            --title "${PR_TITLE}" \
            --body "${PR_BODY}" \
            --base "${TARGET_BRANCH}" \
            --repo "${GH_REPO}" \
            2>&1 | grep "https://github.com" | head -1)
        echo "${PR_URL}"
        ;;

    gitlab)
        # Requires: GITLAB_TOKEN
        if [ -z "${GITLAB_TOKEN:-}" ]; then
            echo "ERROR: GITLAB_TOKEN must be set for GitLab MRs" >&2
            exit 1
        fi
        MR_URL=$(glab mr create \
            --title "${PR_TITLE}" \
            --description "${PR_BODY}" \
            --target-branch "${TARGET_BRANCH}" \
            --yes \
            2>&1 | grep "https://" | head -1)
        echo "${MR_URL}"
        ;;

    azure-repos)
        # Requires: ADO_PAT, ADO_ORG, ADO_PROJECT
        if [ -z "${ADO_PAT:-}" ] || [ -z "${ADO_ORG:-}" ] || [ -z "${ADO_PROJECT:-}" ]; then
            echo "ERROR: ADO_PAT, ADO_ORG, and ADO_PROJECT must be set for Azure Repos PRs" >&2
            exit 1
        fi
        PR_JSON=$(az repos pr create \
            --title "${PR_TITLE}" \
            --description "${PR_BODY}" \
            --target-branch "${TARGET_BRANCH}" \
            --org "${ADO_ORG}" \
            --project "${ADO_PROJECT}" \
            --output json 2>/dev/null)
        PR_URL=$(echo "${PR_JSON}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('url',''))" 2>/dev/null || echo "")
        echo "${PR_URL}"
        ;;

    *)
        echo "ERROR: Unknown VCS provider: ${VCS_ID}. Supported: github, gitlab, azure-repos" >&2
        exit 1
        ;;
esac
