#!/usr/bin/env bash
# fetch-dashboard-failures.sh — Fetch test failures from the timeline-dashboard API.
# Queries the categorization report, cross-references with runs for test file mapping,
# and optionally fetches Jenkins console logs for each failure.
#
# Usage: fetch-dashboard-failures.sh [options]
# Options:
#   --folder <folder>      Jenkins folder to filter (default: Staging). Aliases: Stg->Staging
#   --view <view>          Jenkins view (default: AA_Release)
#   --category <cat>       Filter by category (default: automation_issue)
#   --output <path>        Output JSON path (default: stdout)
#   --job <job_name>       Filter to a specific job name
#   --with-logs            Fetch Jenkins console log for each failure (slower)
#
# Environment:
#   DASHBOARD_URL          Dashboard base URL (default: http://52.51.14.138:3456)
#   E2E_FRAMEWORK_PATH     Path to E2E framework repo (for test file discovery)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DASHBOARD_URL="${DASHBOARD_URL:-http://52.51.14.138:3456}"
FOLDER="Staging"
VIEW="AA_Release"
CATEGORY="automation_issue"
OUTPUT=""
JOB_FILTER=""
WITH_LOGS="false"
E2E_PATH="${E2E_FRAMEWORK_PATH:-}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --folder)    FOLDER="$2"; shift 2 ;;
        --view)      VIEW="$2"; shift 2 ;;
        --category)  CATEGORY="$2"; shift 2 ;;
        --output)    OUTPUT="$2"; shift 2 ;;
        --job)       JOB_FILTER="$2"; shift 2 ;;
        --with-logs) WITH_LOGS="true"; shift ;;
        *)           echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Normalize folder aliases to dashboard folder names
# ---------------------------------------------------------------------------
case "$FOLDER" in
    Stg|stg)       FOLDER="Staging" ;;
    Dev|dev)       FOLDER="Dev" ;;
    Prod|prod)     FOLDER="Prod" ;;
    Staging)       ;; # already correct
esac

# ---------------------------------------------------------------------------
# Temp dir for intermediate files
# ---------------------------------------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
# Fetch data from dashboard API
# ---------------------------------------------------------------------------
REPORT_URL="${DASHBOARD_URL}/api/categorization/report?folder=${FOLDER}&view=${VIEW}"
curl -sf "$REPORT_URL" > "$TMPDIR/report.json" 2>/dev/null || {
    echo "{\"error\": \"Failed to fetch categorization report from $REPORT_URL\"}" >&2
    exit 1
}

curl -sf "${DASHBOARD_URL}/api/runs?status=failed&limit=500" > "$TMPDIR/runs.json" 2>/dev/null || echo '{"runs":[]}' > "$TMPDIR/runs.json"

# ---------------------------------------------------------------------------
# Build testName -> file path mapping from framework test files
# ---------------------------------------------------------------------------
if [ -n "$E2E_PATH" ] && [ -d "$E2E_PATH/tests" ]; then
    _E2E="$E2E_PATH" _OUT="$TMPDIR/testname_map.json" python3 -c "
import os, re, json
framework = os.environ['_E2E']
mapping = {}
for root, dirs, files in os.walk(os.path.join(framework, 'tests')):
    for f in files:
        if f.endswith('.test.js'):
            fpath = os.path.join(root, f)
            relpath = os.path.relpath(fpath, framework)
            try:
                with open(fpath) as fh:
                    content = fh.read(2000)
                    m = re.search(r'(?:let\s+)?testName\s*=\s*[\"\x27\x60]([^\"\x27\x60]+)', content)
                    if m:
                        mapping[m.group(1)] = relpath
            except:
                pass
json.dump(mapping, open(os.environ['_OUT'], 'w'))
" 2>/dev/null || echo '{}' > "$TMPDIR/testname_map.json"
else
    echo '{}' > "$TMPDIR/testname_map.json"
fi

# ---------------------------------------------------------------------------
# Write the processing script to a temp file and execute it
# ---------------------------------------------------------------------------
cat > "$TMPDIR/process.py" << 'PYEOF'
import json, os, re, sys
from datetime import datetime, timezone
from urllib.request import urlopen, Request

tmpdir = os.environ['_TMPDIR']
folder = os.environ['_FOLDER']
view = os.environ['_VIEW']
category = os.environ['_CATEGORY']
job_filter = os.environ['_JOB_FILTER']
dashboard_url = os.environ['_DASHBOARD_URL']
with_logs = os.environ['_WITH_LOGS'] == 'true'

with open(f'{tmpdir}/report.json') as f:
    report = json.load(f)
with open(f'{tmpdir}/runs.json') as f:
    runs_data = json.load(f)
with open(f'{tmpdir}/testname_map.json') as f:
    testname_map = json.load(f)

categories = report.get('categories', {})
items = categories.get(category, [])

if job_filter:
    items = [i for i in items if job_filter.lower() in i.get('job_name', '').lower()]

# Build job_name -> test_name mapping from runs table.
# Runs have folder-prefixed job_name (e.g., "Staging/ui_connectors_github"),
# categorization has bare job_name (e.g., "ui_connectors_github").
job_to_testname = {}
for r in runs_data.get('runs', []):
    jn = r.get('job_name', '')
    tn = r.get('test_name', '')
    if jn and tn:
        job_to_testname[jn] = tn
        if '/' in jn:
            job_to_testname[jn.split('/')[-1]] = tn

def resolve_test_file(job_name):
    """Three-step: job_name -> test_name (runs table) -> file path (testName map)."""
    # Step 1: job_name -> test_name via runs
    test_name = job_to_testname.get(job_name)
    if not test_name:
        for prefix in [folder + '/', folder.lower() + '/', 'Dev/', 'Stg/', 'Staging/', 'Prod/']:
            test_name = job_to_testname.get(prefix + job_name)
            if test_name:
                break

    if test_name:
        # Step 2: strip env suffix (_stg, _dev, _prod)
        clean_name = re.sub(r'_(stg|dev|prod)$', '', test_name)
        # Step 3: testName -> file path
        if clean_name in testname_map:
            return {'test_name': test_name, 'test_file': testname_map[clean_name], 'method': 'runs+testname'}
        for tn, fp in testname_map.items():
            if tn.lower() == clean_name.lower():
                return {'test_name': test_name, 'test_file': fp, 'method': 'runs+testname(ci)'}

    # Fallback: heuristic from job_name
    clean_job = re.sub(r'^_\d+_\d+_', '', job_name)
    clean_job = re.sub(r'^(ui_|API_)', '', clean_job)
    camel = re.sub(r'_(\w)', lambda m: m.group(1).upper(), clean_job)
    for variant in [clean_job, camel, clean_job.replace('_', '')]:
        if variant in testname_map:
            return {'test_name': test_name, 'test_file': testname_map[variant], 'method': 'jobname_heuristic'}
        for tn, fp in testname_map.items():
            if tn.lower() == variant.lower():
                return {'test_name': test_name, 'test_file': fp, 'method': 'jobname_heuristic(ci)'}

    return {'test_name': test_name, 'test_file': None, 'method': 'unresolved'}

def fetch_log_chunk(job_name, build_number):
    """Fetch Jenkins console log context for a specific build."""
    if not build_number:
        return None
    url = f'{dashboard_url}/api/jenkins/job/{folder}/{job_name}/build/{build_number}/error-context'
    try:
        req = Request(url, headers={'Accept': 'application/json'})
        resp = urlopen(req, timeout=10)
        data = json.loads(resp.read())
        return data.get('logChunk')
    except Exception:
        return None

def fetch_full_console(job_name, build_number):
    """Fetch full Jenkins console output (for test file extraction)."""
    if not build_number:
        return None
    url = f'{dashboard_url}/api/jenkins/job/{folder}/{job_name}/build/{build_number}/output'
    try:
        req = Request(url, headers={'Accept': 'text/plain'})
        resp = urlopen(req, timeout=15)
        return resp.read().decode('utf-8', errors='replace')
    except Exception:
        return None

def extract_test_from_console(console_text):
    """Extract test file name from Jenkins console log.

    The Jenkins pipeline log contains two forms:
    1. Template:  npx playwright test ${testName}.test --headed  (useless)
    2. Expanded:  + npx playwright test connectorsUI.test --headed  (from sh -x)

    We want the expanded form (prefixed with '+' from shell trace).
    Also matches: + PLAYWRIGHT_JUNIT_OUTPUT_NAME=... npx playwright test foo.test
    """
    if not console_text:
        return None
    # Match the shell-expanded line: starts with + (sh trace), contains npx playwright test <name>.test
    # The + line has the actual resolved variable value
    m = re.search(r'^\+.*npx playwright test\s+(\S+?)\.test\b', console_text, re.MULTILINE)
    if m:
        raw = m.group(1)  # e.g., "connectorsUI" or "tests/api-tests/.../getConnectors.api"
        # Skip if it's still a variable reference
        if '$' in raw or '{' in raw:
            return None
        # If it has a path, return the last component (strip .api suffix if present)
        name = raw.split('/')[-1]
        # Remove .api suffix for API test files (e.g., "getConnectors.api" -> "getConnectors.api")
        # Actually keep it — the testName in .api.test.js files includes ".api"
        return name
    return None

def resolve_via_console(job_name, build_number):
    """Last-resort: fetch full console log and extract test name."""
    console = fetch_full_console(job_name, build_number)
    test_name_from_log = extract_test_from_console(console)
    if not test_name_from_log:
        return None

    # Look up in testname_map
    if test_name_from_log in testname_map:
        return {'test_name': test_name_from_log, 'test_file': testname_map[test_name_from_log], 'method': 'console_log'}

    # Case-insensitive
    for tn, fp in testname_map.items():
        if tn.lower() == test_name_from_log.lower():
            return {'test_name': test_name_from_log, 'test_file': fp, 'method': 'console_log(ci)'}

    # Try to find the .test.js file directly
    e2e_path = os.environ.get('E2E_FRAMEWORK_PATH', os.environ.get('_E2E', ''))
    if e2e_path:
        import subprocess
        try:
            result = subprocess.run(
                ['find', e2e_path + '/tests', '-name', f'{test_name_from_log}.test.js'],
                capture_output=True, text=True, timeout=5
            )
            if result.stdout.strip():
                full = result.stdout.strip().split('\n')[0]
                relpath = os.path.relpath(full, e2e_path)
                return {'test_name': test_name_from_log, 'test_file': relpath, 'method': 'console_log+find'}
        except Exception:
            pass

    return {'test_name': test_name_from_log, 'test_file': None, 'method': 'console_log(no_file)'}

output = {
    'fetched_at': datetime.now(timezone.utc).isoformat(),
    'dashboard_url': dashboard_url,
    'folder': folder,
    'view': view,
    'category_filter': category,
    'total_failures': report.get('total', 0),
    'matched_count': len(items),
    'resolved_count': 0,
    'failures': []
}

resolved = 0
for item in items:
    job_name = item.get('job_name', '')
    build_number = item.get('build_number')

    # Step 1: Try runs table + testname map
    resolution = resolve_test_file(job_name)

    # Step 2: If unresolved, fetch console log and extract test name
    if not resolution.get('test_file') and build_number:
        console_resolution = resolve_via_console(job_name, build_number)
        if console_resolution and console_resolution.get('test_file'):
            resolution = console_resolution
        elif console_resolution and console_resolution.get('test_name'):
            # Got test name from console but no file — update resolution
            resolution['test_name'] = console_resolution['test_name']
            resolution['method'] = console_resolution['method']

    if resolution.get('test_file'):
        resolved += 1

    # Fetch error-context log chunk (always, for debug agent context)
    log_chunk = fetch_log_chunk(job_name, build_number) if with_logs else None

    output['failures'].append({
        'job_name': job_name,
        'build_number': build_number,
        'category': item.get('category', ''),
        'confidence': item.get('confidence', 0),
        'explanation': item.get('explanation', ''),
        'suggested_action': item.get('suggested_action', ''),
        'reason': item.get('reason', ''),
        'org_name': item.get('org_name', ''),
        'assignee': item.get('assignee'),
        'categorized_at': item.get('categorized_at', ''),
        'test_name': resolution.get('test_name'),
        'test_file': resolution.get('test_file'),
        'resolution_method': resolution.get('method'),
        'log_chunk': log_chunk
    })

output['resolved_count'] = resolved
print(json.dumps(output, indent=2))
PYEOF

# Run the processor
RESULT=$(_FOLDER="$FOLDER" _VIEW="$VIEW" _CATEGORY="$CATEGORY" _JOB_FILTER="$JOB_FILTER" \
_DASHBOARD_URL="$DASHBOARD_URL" _WITH_LOGS="$WITH_LOGS" _TMPDIR="$TMPDIR" \
python3 "$TMPDIR/process.py")

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ -n "$OUTPUT" ]; then
    mkdir -p "$(dirname "$OUTPUT")"
    echo "$RESULT" > "$OUTPUT"
    STATS=$(echo "$RESULT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d["matched_count"])+" failures ("+str(d["resolved_count"])+" resolved to test files)")')
    echo "[fetch-dashboard-failures] Wrote $STATS to $OUTPUT" >&2
else
    echo "$RESULT"
fi
