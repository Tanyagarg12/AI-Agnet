---
name: qa-maintain-tests
description: Run existing ai-done E2E tests against staging/dev to check for regressions. Creates maintenance Jira tickets for failures. On-demand.
disable-model-invocation: true
argument-hint: "[OXDEV-NNN] [--env dev|stg]"
---

# Test Maintenance Pipeline

Check existing ai-done E2E tests for regressions. Runs tests, reports results, creates maintenance tickets for failures.

## Usage

```
/qa-maintain-tests                    # check all ai-done tests
/qa-maintain-tests OXDEV-123          # check specific ticket's test
/qa-maintain-tests --env dev          # target dev environment
```

## Flags

Parse `$ARGUMENTS`:
- **Ticket key** (optional): Check only this ticket's test. If omitted, check all ai-done tickets.
- **`--env dev|stg`**: Target environment. Default: `stg`.

---

## Process

### Step 1: Find Tests to Check

If a specific ticket key was provided:
- Read `memory/tickets/<KEY>/checkpoint.json`
- Verify `status: "completed"`
- Read `memory/tickets/<KEY>/implementation.md` for test file path

If no ticket key:
- Scan `memory/tickets/*/checkpoint.json` for all tickets with `status: "completed"` and `retrospective: true`
- Build a list of test file paths from each ticket's implementation.md

### Step 2: Verify Tests Exist in Framework

For each test:
```bash
cd $E2E_FRAMEWORK_PATH
git fetch origin developmentV2
git show origin/developmentV2:<test-file-path> > /dev/null 2>&1 && echo "exists" || echo "not found"
```

If the test file doesn't exist on `origin/developmentV2` (not merged yet or deleted), skip it.

### Step 3: Run Tests

Read environment from `config/environments.json` based on `--env` flag.

For each test file:
```bash
cd $E2E_FRAMEWORK_PATH
envFile=<env_file> npx playwright test <test-file> --retries=0 --trace on
```

Capture: exit code, stdout, stderr.

### Step 4: Process Results

Create/update `memory/maintenance/maintenance-log.json`:
```json
{
    "last_run": "<ISO-8601>",
    "environment": "stg",
    "results": [
        {
            "ticket_key": "OXDEV-123",
            "test_file": "tests/UI/issues/issuesFilters.test.js",
            "status": "healthy",
            "ran_at": "<ISO-8601>"
        },
        {
            "ticket_key": "OXDEV-456",
            "test_file": "tests/UI/dashboard/dashboardWidgets.test.js",
            "status": "failed",
            "error": "selector_not_found: data-testid='widget-chart' not found",
            "ran_at": "<ISO-8601>",
            "maintenance_ticket": "OXDEV-789"
        }
    ]
}
```

### Step 5: Create Maintenance Tickets for Failures

For each failed test, check if a maintenance ticket already exists:
```bash
acli jira workitem search --jql "project = OXDEV AND labels = 'e2e-maintenance' AND summary ~ '<original-ticket-key>' AND status != Done" --fields "key,summary,status"
```

If no existing ticket, create one:
```bash
acli jira workitem create --project "OXDEV" --type "Task" --summary "E2E Maintenance: <original-ticket-key> - <test-name> regression"  --description "## Regression Detected

**Original ticket**: <original-ticket-key>
**Test file**: <test-file-path>
**Environment**: <env>
**Error**: <error-summary>

## Steps to Reproduce
1. Run: envFile=<env> npx playwright test <test-file> --retries=0 --trace on
2. Observe failure in test step: <failing-step>

## Expected
All tests pass (they passed when originally created).

## Actual
<failure-details>

## Trace
Trace file available at: <trace-path>"
```

Add labels:
```bash
acli jira workitem edit --key "<NEW-KEY>" --labels "ai-ready" "e2e-test" "e2e-maintenance" --yes
```

### Step 6: Present Summary

```
Test Maintenance Results (<env>)

| Ticket | Test | Status | Action |
|--------|------|--------|--------|
| OXDEV-123 | issuesFilters.test.js | HEALTHY | — |
| OXDEV-456 | dashboardWidgets.test.js | FAILED | Created OXDEV-789 |

Healthy: N | Failed: N | Skipped: N (not merged)
```

---

## Error Handling

- If a test hangs (>5 min), kill the process and mark as "timeout"
- If framework checkout fails, skip all tests and report error
- If Jira ticket creation fails, log error and continue with other tests
- Always write maintenance-log.json even on partial failure

## Directory Setup

Run `mkdir -p memory/maintenance` before first use.
