#!/usr/bin/env bash
# gp-parse-results.sh
# Parses test results from any framework into canonical run-results.json.
# Usage: ./scripts/gp-parse-results.sh <run_id> <framework> <project_root>

set -uo pipefail

RUN_ID="${1:?RUN_ID required}"
FRAMEWORK="${2:?FRAMEWORK required}"
PROJECT_ROOT="${3:?PROJECT_ROOT required}"

MEMORY_DIR="memory/gp-runs/${RUN_ID}"
OUTPUT_FILE="${MEMORY_DIR}/run-results.json"

# Load result file pattern from framework config
RESULT_PATTERN=$(python3 -c "
import json
with open('config/frameworks/${FRAMEWORK}.json') as f:
    cfg = json.load(f)
print(cfg.get('result_file_pattern', 'results.xml'))
" 2>/dev/null || echo "results.xml")

RESULT_FORMAT=$(python3 -c "
import json
with open('config/frameworks/${FRAMEWORK}.json') as f:
    cfg = json.load(f)
print(cfg.get('result_format', 'junit-xml'))
" 2>/dev/null || echo "junit-xml")

# Find the result file
RESULT_FILE=$(find "${PROJECT_ROOT}" -name "$(basename ${RESULT_PATTERN})" 2>/dev/null | head -1)

if [ -z "${RESULT_FILE}" ]; then
    echo "WARNING: Result file not found (pattern: ${RESULT_PATTERN})" >&2
    # Write a failure result indicating we couldn't parse
    python3 -c "
import json, datetime
result = {
    'run_id': '${RUN_ID}',
    'status': 'failed',
    'framework': '${FRAMEWORK}',
    'total': 0,
    'passed': 0,
    'failed': 1,
    'skipped': 0,
    'duration_ms': 0,
    'failures': [{
        'test_name': 'PARSE_ERROR',
        'error': 'Result file not found: ${RESULT_PATTERN}',
        'error_type': 'syntax_error'
    }],
    'artifacts': {},
    'completed_at': datetime.datetime.utcnow().isoformat()
}
print(json.dumps(result, indent=2))
" > "${OUTPUT_FILE}"
    exit 0
fi

# Parse based on format
python3 << PYEOF
import json
import datetime
import os
import sys

run_id = '${RUN_ID}'
framework = '${FRAMEWORK}'
result_file = '${RESULT_FILE}'
project_root = '${PROJECT_ROOT}'
output_file = '${OUTPUT_FILE}'

def classify_error(error_msg):
    error_lower = error_msg.lower()
    if any(x in error_lower for x in ['locator', 'nosuchelement', 'element not found', 'no such element']):
        return 'selector_not_found'
    if any(x in error_lower for x in ['timeout', 'timed out', 'waiting for']):
        return 'timeout'
    if any(x in error_lower for x in ['assertionerror', 'expected', 'assert', 'failed']):
        return 'assertion_failure'
    if any(x in error_lower for x in ['syntaxerror', 'importerror', 'modulenotfounderror', 'nameerror']):
        return 'syntax_error'
    if any(x in error_lower for x in ['401', '403', 'unauthorized', 'login', 'authentication']):
        return 'auth_failure'
    if any(x in error_lower for x in ['connectionrefused', 'econnrefused', 'network', 'unreachable']):
        return 'network_error'
    return 'assertion_failure'

result = {
    'run_id': run_id,
    'framework': framework,
    'total': 0,
    'passed': 0,
    'failed': 0,
    'skipped': 0,
    'duration_ms': 0,
    'failures': [],
    'artifacts': {},
    'completed_at': datetime.datetime.utcnow().isoformat()
}

format_type = '${RESULT_FORMAT}'

if format_type == 'junit-xml':
    import xml.etree.ElementTree as ET
    try:
        tree = ET.parse(result_file)
        root = tree.getroot()

        # Handle both <testsuites> and <testsuite> root
        if root.tag == 'testsuites':
            suites = root.findall('testsuite')
        elif root.tag == 'testsuite':
            suites = [root]
        else:
            suites = root.findall('.//testsuite')

        total = passed = failed = skipped = 0
        duration_ms = 0
        failures = []

        for suite in suites:
            suite_tests = int(suite.get('tests', 0))
            suite_failures = int(suite.get('failures', 0))
            suite_errors = int(suite.get('errors', 0))
            suite_skipped = int(suite.get('skipped', 0))
            suite_time = float(suite.get('time', 0))
            duration_ms += int(suite_time * 1000)

            total += suite_tests
            failed += suite_failures + suite_errors
            skipped += suite_skipped
            passed += suite_tests - suite_failures - suite_errors - suite_skipped

            for tc in suite.findall('testcase'):
                failure_el = tc.find('failure') or tc.find('error')
                if failure_el is not None:
                    error_msg = failure_el.get('message', '') or (failure_el.text or '')
                    failures.append({
                        'test_name': tc.get('name', 'unknown'),
                        'class_name': tc.get('classname', ''),
                        'error': error_msg[:500],  # truncate
                        'error_type': classify_error(error_msg),
                        'screenshot': None,
                        'video': None
                    })

        result.update({
            'total': total,
            'passed': passed,
            'failed': failed,
            'skipped': skipped,
            'duration_ms': duration_ms,
            'failures': failures
        })
    except Exception as e:
        result['failures'] = [{'test_name': 'PARSE_ERROR', 'error': str(e), 'error_type': 'syntax_error'}]
        result['failed'] = 1

elif format_type == 'playwright-json':
    try:
        with open(result_file) as f:
            pw_data = json.load(f)
        suites = pw_data.get('suites', [])
        # Flatten all specs
        def flatten_specs(suites):
            specs = []
            for s in suites:
                specs.extend(s.get('specs', []))
                specs.extend(flatten_specs(s.get('suites', [])))
            return specs
        specs = flatten_specs(suites)
        total = len(specs)
        passed = sum(1 for s in specs if s.get('ok'))
        failed = sum(1 for s in specs if not s.get('ok'))
        failures = []
        for s in specs:
            if not s.get('ok'):
                for test in s.get('tests', []):
                    for res in test.get('results', []):
                        err = res.get('error', {})
                        msg = err.get('message', s.get('title', 'unknown failure'))
                        failures.append({
                            'test_name': s.get('title', 'unknown'),
                            'error': msg[:500],
                            'error_type': classify_error(msg),
                            'screenshot': None,
                            'video': None
                        })
        result.update({'total': total, 'passed': passed, 'failed': failed, 'failures': failures})
    except Exception as e:
        result['failures'] = [{'test_name': 'PARSE_ERROR', 'error': str(e), 'error_type': 'syntax_error'}]
        result['failed'] = 1

# Find artifacts
screenshots = []
for ext in ['png', 'jpg']:
    for p in [f'{project_root}/test-results', f'{project_root}/reports/screenshots']:
        if os.path.isdir(p):
            screenshots += [os.path.join(p, f) for f in os.listdir(p) if f.endswith(f'.{ext}')]

videos = []
for p in [f'{project_root}/test-results']:
    if os.path.isdir(p):
        videos += [os.path.join(p, f) for f in os.listdir(p) if f.endswith('.webm')]

result['artifacts'] = {
    'junit_xml': result_file,
    'screenshots': screenshots[:10],  # limit to 10
    'videos': videos[:5],
    'html_report': None,
    'allure_results': None
}

# Add screenshot paths to individual failures
for i, failure in enumerate(result['failures']):
    fail_screenshots = [s for s in screenshots if 'FAIL' in s or 'fail' in s]
    if i < len(fail_screenshots):
        failure['screenshot'] = fail_screenshots[i]

result['status'] = 'passed' if result['failed'] == 0 else 'failed'

with open(output_file, 'w') as f:
    json.dump(result, f, indent=2)

print(f"Parsed: {result['total']} total, {result['passed']} passed, {result['failed']} failed")
PYEOF
