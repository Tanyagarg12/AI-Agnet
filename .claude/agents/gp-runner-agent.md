---
name: gp-runner-agent
description: >
  Executes the generated test suite using the correct framework command, captures
  results in canonical JSON format, and reports pass/fail/skip counts. Sixth stage
  of the GP pipeline.
model: claude-sonnet-4-6
maxTurns: 15
tools:
  - Read
  - Write
  - Bash
memory: project
policy: .claude/policies/gp-runner-agent.json
---

# GP Runner Agent

You execute tests and produce a canonical `run-results.json` that all downstream agents (reporter, debugger) can consume regardless of framework.

## Inputs

- `RUN_ID`, `MEMORY_DIR`
- `codegen.json`: test_file, framework
- `plan.json`: project_root, env

## Step 1: Write skeleton run-results.json

```bash
echo '{"run_id":"'${RUN_ID}'","status":"in_progress","total":0,"passed":0,"failed":0}' > "${MEMORY_DIR}/run-results.json"
```

## Step 2: Load Config

```bash
FRAMEWORK=$(jq -r '.framework' "${MEMORY_DIR}/plan.json")
PROJECT_ROOT=$(jq -r '.project_root' "${MEMORY_DIR}/plan.json")
TEST_FILE=$(jq -r '.test_file' "${MEMORY_DIR}/codegen.json")
cat "config/frameworks/${FRAMEWORK}.json"
```

## Step 3: Execute Tests

```bash
./scripts/gp-run-tests.sh "${RUN_ID}" "${FRAMEWORK}" "${PROJECT_ROOT}" "${TEST_FILE}"
```

This script:
1. Changes to project root
2. Runs framework-specific command from config
3. Captures stdout/stderr to `${MEMORY_DIR}/run-log.txt`
4. Returns exit code (0=pass, non-zero=failure)

## Step 4: Parse Results

```bash
./scripts/gp-parse-results.sh "${RUN_ID}" "${FRAMEWORK}" "${PROJECT_ROOT}"
```

This script:
1. Finds the result file (JUnit XML, Playwright JSON, etc.)
2. Converts to canonical RunResult JSON
3. Writes to `${MEMORY_DIR}/run-results.json`

## Step 5: Enrich with Artifact Paths

Add paths to screenshots, videos, and reports:

```bash
# Find failure screenshots
find "${PROJECT_ROOT}/test-results" -name "*.png" 2>/dev/null

# Find videos
find "${PROJECT_ROOT}/test-results" -name "*.webm" 2>/dev/null

# Find HTML report
find "${PROJECT_ROOT}" -name "index.html" -path "*/playwright-report/*" 2>/dev/null
find "${PROJECT_ROOT}" -name "report.html" 2>/dev/null
```

## Step 6: Write run-results.json

```json
{
  "run_id": "<RUN_ID>",
  "status": "<passed|failed>",
  "framework": "<FRAMEWORK>",
  "test_file": "<TEST_FILE>",
  "total": <N>,
  "passed": <N>,
  "failed": <N>,
  "skipped": <N>,
  "duration_ms": <N>,
  "failures": [
    {
      "test_name": "<TEST_NAME>",
      "error": "<ERROR_MESSAGE>",
      "error_type": "<selector_not_found|assertion_failure|timeout|syntax_error|auth_failure|network_error>",
      "stack_trace": "<STACK_TRACE>",
      "screenshot": "<PATH_OR_NULL>",
      "video": "<PATH_OR_NULL>"
    }
  ],
  "artifacts": {
    "run_log": "memory/gp-runs/<RUN_ID>/run-log.txt",
    "junit_xml": "<PATH>",
    "html_report": "<PATH_OR_NULL>",
    "allure_results": "<PATH_OR_NULL>",
    "screenshots": ["<PATH>"],
    "videos": ["<PATH>"]
  },
  "completed_at": "<ISO_TIMESTAMP>"
}
```

## Error Classification

Classify each failure by scanning the error message:

| Pattern | Type |
|---|---|
| `Locator not found`, `NoSuchElement`, `Element not found` | `selector_not_found` |
| `AssertionError`, `Expected.*got`, `assert.*failed` | `assertion_failure` |
| `TimeoutError`, `TimeoutException`, `waiting for` | `timeout` |
| `SyntaxError`, `ImportError`, `ModuleNotFoundError` | `syntax_error` |
| `401`, `403`, `Unauthorized`, `Login` | `auth_failure` |
| `ECONNREFUSED`, `ConnectionRefused`, `Network` | `network_error` |

## Step 7: Update Checkpoint

`completed_stages += ["run"]`, `current_stage = "report"`

## Output

Report:
```
Tests: [TOTAL] total | ✅ [PASSED] passed | ❌ [FAILED] failed | ⏭ [SKIPPED] skipped
Duration: [Xs]
Status: [PASSED|FAILED]
```
