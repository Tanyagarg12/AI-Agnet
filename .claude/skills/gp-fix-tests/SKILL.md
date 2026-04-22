---
name: gp-fix-tests
description: >
  Auto-fix failing tests in any framework. Reads a test file or results file,
  diagnoses failures, looks up the failure catalog for known patterns, re-inspects
  the live UI if needed, applies fixes, and creates a PR with the fixed code.
argument-hint: "<test-file-or-results-json> [--framework playwright-js|selenium-python|...] [--env staging] [--project-path /abs/path] [--create-pr] [--ticket PROJ-123]"
---

# GP Fix Tests — Automated Test Failure Repair

You repair failing tests in any framework using a structured diagnosis-then-fix approach.

## Step 1: Parse Arguments

```
FLAGS:
  first arg    → path to test file OR run-results.json
  --framework  → framework override (auto-detected from file if not provided)
  --env        → environment to use for live inspection (default: staging)
  --project-path → root of the test project
  --create-pr  → create a PR after successful fix (requires clean tests)
  --ticket     → link to originating ticket (for PR description)
```

## Step 2: Load Run Results

If argument is a `run-results.json`:
```bash
cat <results-file>
```

If argument is a test file: run the tests first to get a fresh results file.

## Step 3: Classify Failures

For each failed test, classify the error:

| Error Pattern | Type | Primary Fix Strategy |
|---|---|---|
| `Element not found`, `Locator not found`, `NoSuchElementException` | `selector_not_found` | Re-inspect DOM, update selector |
| `AssertionError`, `Expected X got Y` | `assertion_failure` | Re-read requirements, fix expected value |
| `TimeoutError`, `TimeoutException` | `timeout` | Add wait, increase timeout, await API |
| `SyntaxError`, `ImportError`, `ModuleNotFoundError` | `syntax_error` | Fix code, add missing import |
| `401`, `403`, `Unauthorized`, `Login failed` | `auth_failure` | Fix credentials, check env vars |
| `ConnectionRefused`, `ECONNREFUSED`, `Network` | `network_error` | Check env URL, check service health |

## Step 4: Check Failure Catalog

```bash
grep -A 5 "<error_type>" memory/gp/failure-catalog.md
```

If a known pattern matches: apply the documented fix directly.

## Step 5: Diagnose — Re-Inspect Live UI (for selector failures)

Use CDP or playwright-cli to inspect the current DOM state:
1. Navigate to the failing page
2. Search for the expected element using multiple strategies
3. Capture updated selectors
4. Compare with current selector in test code

## Step 6: Apply Fixes

Apply fixes to test code, committing each logical fix separately:

```
fix(tests): update selector for <element> — data-testid changed in latest deploy
fix(tests): add waitForResponse before table assertion — data loads async
fix(tests): correct expected redirect URL after SSO — staging vs prod difference
```

After each fix: re-run the specific failing test to verify.

## Step 7: Full Run Verification

After all individual fixes: run the complete test suite to ensure no regressions:
```bash
./scripts/gp-run-tests.sh <RUN_ID> <TEST_FILE>
```

## Step 8: Create PR (Optional)

If `--create-pr` flag and all tests now passing:
- Push fixes to the current branch (or create a new `fix/` branch)
- Create PR with description: which tests failed, root cause, what was changed

## Step 9: Update Failure Catalog

Append to `memory/gp/failure-catalog.md`:
```markdown
### [<DATE>] <FRAMEWORK> | <FAILURE_TYPE>
- **Test**: <test_name>
- **Error**: <error_message>
- **Root Cause**: <diagnosed cause>
- **Fix Applied**: <what changed>
- **Reusable Pattern**: <generalized lesson>
```

## Rules

- NEVER delete a test — fix it or mark it as skipped with a reason comment
- NEVER change the test's intent (what is being verified)
- NEVER hardcode values that should come from config or env vars
- Fix the smallest change that makes the test pass
- If the fix would change application behavior, comment on the ticket instead
