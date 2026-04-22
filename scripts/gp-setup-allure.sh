#!/usr/bin/env bash
# gp-setup-allure.sh
# Installs and configures Allure reporting for a given framework.
# Usage: ./scripts/gp-setup-allure.sh <framework_id> <project_root>

set -uo pipefail

FRAMEWORK="${1:?FRAMEWORK required}"
PROJECT_ROOT="${2:-.}"

echo "Setting up Allure reporting for: ${FRAMEWORK}"

# Load allure config from framework config
ALLURE_CFG=$(python3 -c "
import json
with open('config/frameworks/${FRAMEWORK}.json') as f:
    cfg = json.load(f)
allure = cfg.get('reporting', {}).get('allure', {})
print(json.dumps(allure))
" 2>/dev/null || echo "{}")

INSTALL_CMD=$(echo "${ALLURE_CFG}" | python3 -c "import json,sys; a=json.load(sys.stdin); print(a.get('install',''))" 2>/dev/null || echo "")

if [ -z "${INSTALL_CMD}" ]; then
    echo "No Allure install command found for: ${FRAMEWORK}"
    exit 0
fi

cd "${PROJECT_ROOT}"

echo "Running: ${INSTALL_CMD}"
if eval "${INSTALL_CMD}"; then
    echo "Allure setup complete for ${FRAMEWORK}"
else
    echo "WARNING: Allure setup failed (non-fatal)" >&2
fi

# Ensure allure-results directory exists
mkdir -p allure-results
echo "allure-results/" >> .gitignore 2>/dev/null || true
echo "allure-report/" >> .gitignore 2>/dev/null || true
