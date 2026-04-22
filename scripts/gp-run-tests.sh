#!/usr/bin/env bash
# gp-run-tests.sh
# Framework-agnostic test runner dispatcher.
# Usage: ./scripts/gp-run-tests.sh <run_id> <framework> <project_root> [test_file]
# Returns: 0 if all tests pass, 1 if any fail

set -uo pipefail

RUN_ID="${1:?RUN_ID required}"
FRAMEWORK="${2:?FRAMEWORK required}"
PROJECT_ROOT="${3:?PROJECT_ROOT required}"
TEST_FILE="${4:-}"

MEMORY_DIR="memory/gp-runs/${RUN_ID}"
LOG_FILE="${MEMORY_DIR}/run-log.txt"

mkdir -p "${MEMORY_DIR}"

echo "=== GP Test Runner ===" | tee "${LOG_FILE}"
echo "Framework: ${FRAMEWORK}" | tee -a "${LOG_FILE}"
echo "Project: ${PROJECT_ROOT}" | tee -a "${LOG_FILE}"
echo "Test file: ${TEST_FILE:-all}" | tee -a "${LOG_FILE}"
echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "${LOG_FILE}"
echo "========================" | tee -a "${LOG_FILE}"

# Load framework config to get run command
RUN_CMD=$(python3 -c "
import json, sys
try:
    with open('config/frameworks/${FRAMEWORK}.json') as f:
        cfg = json.load(f)
    cmd = cfg.get('run_command') if '${TEST_FILE}' else cfg.get('run_all_command', cfg.get('run_command'))
    if '${TEST_FILE}':
        cmd = cmd.replace('{test_file}', '${TEST_FILE}')
    print(cmd)
except Exception as e:
    print(f'echo ERROR_LOADING_CONFIG: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)

if [ -z "${RUN_CMD}" ]; then
    echo "ERROR: Could not load run command for framework: ${FRAMEWORK}" | tee -a "${LOG_FILE}"
    exit 1
fi

echo "Command: ${RUN_CMD}" | tee -a "${LOG_FILE}"
echo "---" | tee -a "${LOG_FILE}"

# Change to project root and run
cd "${PROJECT_ROOT}"

# Execute with timeout (10 minutes)
EXIT_CODE=0
timeout 600 bash -c "${RUN_CMD}" 2>&1 | tee -a "$(pwd)/../../../${LOG_FILE}" || EXIT_CODE=$?

echo "---" | tee -a "$(pwd)/../../../${LOG_FILE}"
echo "Exit code: ${EXIT_CODE}" | tee -a "$(pwd)/../../../${LOG_FILE}"
echo "Ended: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$(pwd)/../../../${LOG_FILE}"

exit ${EXIT_CODE}
