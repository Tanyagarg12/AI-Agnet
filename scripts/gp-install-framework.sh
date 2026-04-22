#!/usr/bin/env bash
# gp-install-framework.sh
# Installs test framework dependencies for a given framework ID.
# Usage: ./scripts/gp-install-framework.sh <framework_id> <project_root>

set -uo pipefail

FRAMEWORK="${1:?FRAMEWORK required}"
PROJECT_ROOT="${2:-.}"

echo "Installing dependencies for: ${FRAMEWORK} in ${PROJECT_ROOT}"

# Load install commands from framework config
INSTALL_CMDS=$(python3 -c "
import json
with open('config/frameworks/${FRAMEWORK}.json') as f:
    cfg = json.load(f)
cmds = cfg.get('install_commands', [])
for cmd in cmds:
    print(cmd)
" 2>/dev/null)

if [ -z "${INSTALL_CMDS}" ]; then
    echo "No install commands found for framework: ${FRAMEWORK}" >&2
    exit 0
fi

cd "${PROJECT_ROOT}"

while IFS= read -r cmd; do
    [ -z "${cmd}" ] && continue
    echo "Running: ${cmd}"
    if ! eval "${cmd}"; then
        echo "WARNING: Install command failed: ${cmd}" >&2
        # Don't fail hard — some installs are optional or platform-specific
    fi
done <<< "${INSTALL_CMDS}"

echo "Installation complete for ${FRAMEWORK}"
