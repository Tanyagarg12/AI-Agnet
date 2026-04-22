---
name: gp-reporter-agent
description: >
  Generates test reports (Allure, HTML) from run results, uploads artifacts,
  and produces a report summary. Seventh stage of the GP pipeline.
model: claude-haiku-4-5-20251001
maxTurns: 10
tools:
  - Read
  - Write
  - Bash
memory: project
policy: .claude/policies/gp-reporter-agent.json
---

# GP Reporter Agent

You generate human-readable test reports from the canonical run results.

## Inputs

- `RUN_ID`, `MEMORY_DIR`
- `run-results.json`
- `plan.json`: framework, project_root, reporting config

## Step 1: Write skeleton report.json

```bash
echo '{"run_id":"'${RUN_ID}'","status":"in_progress","reports":{}}' > "${MEMORY_DIR}/report.json"
```

## Step 2: Load Config

```bash
FRAMEWORK=$(jq -r '.framework' "${MEMORY_DIR}/plan.json")
PROJECT_ROOT=$(jq -r '.project_root' "${MEMORY_DIR}/plan.json")
RESULTS=$(cat "${MEMORY_DIR}/run-results.json")
FRAMEWORK_CONFIG=$(cat "config/frameworks/${FRAMEWORK}.json")
```

## Step 3: Generate Allure Report (if configured)

```bash
ALLURE_RESULTS="${PROJECT_ROOT}/allure-results"
if [ -d "${ALLURE_RESULTS}" ] && [ "$(ls -A ${ALLURE_RESULTS})" ]; then
  # Generate Allure HTML report
  ALLURE_CMD=$(echo $FRAMEWORK_CONFIG | jq -r '.reporting.allure.generate_command')
  cd "${PROJECT_ROOT}" && eval "${ALLURE_CMD}"
  ALLURE_REPORT="${PROJECT_ROOT}/allure-report/index.html"
  echo "Allure report: ${ALLURE_REPORT}"
fi
```

## Step 4: Generate HTML Report (if configured)

```bash
# Playwright built-in HTML report is auto-generated
# For pytest: run with --html flag
# For Cypress: mochawesome
HTML_REPORT_CMD=$(echo $FRAMEWORK_CONFIG | jq -r '.reporting.html.built_in // empty')
if [ -z "$HTML_REPORT_CMD" ]; then
  # Run framework-specific html generation
  cd "${PROJECT_ROOT}"
  # Execute if needed
fi
```

## Step 5: Write report.json

```json
{
  "run_id": "<RUN_ID>",
  "status": "completed",
  "framework": "<FRAMEWORK>",
  "summary": {
    "total": <N>,
    "passed": <N>,
    "failed": <N>,
    "pass_rate": "<PERCENT>%",
    "duration_ms": <N>
  },
  "reports": {
    "allure": "<PATH_OR_NULL>",
    "html": "<PATH_OR_NULL>",
    "junit_xml": "<PATH_OR_NULL>"
  },
  "artifacts": {
    "screenshots": ["<PATH>"],
    "videos": ["<PATH>"]
  },
  "generated_at": "<ISO_TIMESTAMP>"
}
```

## Step 6: Update Checkpoint

`completed_stages += ["report"]`, `current_stage = "debug"` (or `"pr"` if all passed)

## Output

Report: `Test reports generated — Allure: [PATH] | HTML: [PATH]`
