---
name: qa-implement-test
description: Write E2E Playwright test code, run it, and debug failures in a loop. Spawns developer and tester teammates.
disable-model-invocation: true
argument-hint: "[ticket-key]"
---

# Implement E2E Test

Write the E2E Playwright test file (with actions and selectors), run it, and fix failures through a debug loop (max 3 cycles).

## Usage

```
/qa-implement-test OXDEV-123
/qa-implement-test OXDEV-123 --auto
```

## Flags

Parse `$ARGUMENTS` for flags before processing:
- **`--auto`**: Skip plan approval for the developer teammate. Use for fully unattended runs.

Extract the ticket key (first word) and flags from `$ARGUMENTS`.

## Prerequisites

- `memory/tickets/$ARGUMENTS/triage.json` must exist
- `memory/tickets/$ARGUMENTS/exploration.md` should exist
- `memory/tickets/$ARGUMENTS/playwright-data.json` should exist
- The `framework/` directory must be accessible

## Team Structure

Create team `qa-impl-$ARGUMENTS` with developer and tester teammates.

## Process

### Step 1: Load Context

1. Read `memory/tickets/$ARGUMENTS/triage.json`
2. Read `memory/tickets/$ARGUMENTS/exploration.md`
3. Read `memory/tickets/$ARGUMENTS/playwright-data.json`
4. Read `memory/tickets/$ARGUMENTS/checkpoint.json`

### Step 2: Spawn Developer Teammate

Spawn developer teammate (opus):

```
You are the "developer" teammate for Jira ticket $ARGUMENTS.

MANDATORY OUTPUT — THIS IS YOUR #1 PRIORITY:
You MUST write `memory/tickets/$ARGUMENTS/implementation.md` AND commit code before finishing.

STEP 1 — DO THIS IMMEDIATELY (before creating branches or writing code):
Write this skeleton file NOW:

    Write to memory/tickets/$ARGUMENTS/implementation.md:
    # Implementation: $ARGUMENTS
    ## Files Created
    (pending)
    ## Commits
    (pending)

STEP 2 — Read context:
1. Read `.claude/agents/code-writer-agent.md` for full implementation instructions.
2. Read `templates/test-file.md` for the test scaffold template.
3. Read all context files in memory/tickets/$ARGUMENTS/.

FRAMEWORK CONVENTIONS (CRITICAL):
- CommonJS require() -- NO ES module imports
- Double quotes, 4-space indentation, semicolons, no trailing commas
- Tests run serially: test.describe.configure({ mode: "serial", retries: 0 })
- Number tests sequentially: "#1 Navigate", "#2 Login", "#3 Verify..."
- Use setHooks: setBeforeAll, setBeforeEach, setAfterEach, setAfterAll
- Login is always test #1-#2 (navigation + verifyLoginPage + closeWhatsNew)
- Use existing actions from framework/actions/ -- DO NOT duplicate
- Use existing selectors from framework/selectors/ -- DO NOT duplicate
- Use logger.info() for structured logging
- Use expect.soft() for non-blocking assertions when validating multiple properties
- Use environment variables from process.env (SANITY_ORG_NAME, SANITY_USER, etc.)

REPOSITORY SETUP:
- Work in the framework/ directory
- Create branch: test/$ARGUMENTS-<short-slug> from developmentV2
- Ensure branch is based on latest development

FILE CREATION:
1. Test file: framework/tests/UI/<feature_area>/<testName>/<testName>.test.js
2. Actions: framework/actions/<feature_area>.js (add functions or create new file)
3. Selectors: framework/selectors/<feature_area>.json (add entries or create new file)

COMMIT:
- Stage only created/modified files: git add <specific files>
- Commit: `$ARGUMENTS: Add E2E test for <summary>`
- Push: git push -u origin test/$ARGUMENTS-<short-slug>

OUTPUT:
- Write structured JSON to memory/tickets/$ARGUMENTS/code-writer-output.json with EXACT field names: "branch" (NOT branch_name), "commits" (array of hashes), "diff" (top-level combined unified diff from `git diff developmentV2...HEAD`), "files_created", "files_modified", plus test_file, files, files_count, lines_added, lines_deleted, test_steps, feature_doc
- Write summary to memory/tickets/$ARGUMENTS/implementation.md
- Update checkpoint: add "code-writer" to completed_stages

ALL CONTEXT:
<paste triage.json + exploration.md + playwright-data.json>
```

If `--auto` flag was NOT passed: require plan approval before the developer starts writing code.
If `--auto` flag WAS passed: skip plan approval — let the developer proceed immediately.
Wait for developer to complete.

**DASHBOARD REPORT (MANDATORY — EXECUTE BEFORE PROCEEDING TO NEXT PHASE):**
```bash
./scripts/report-to-dashboard.sh $ARGUMENTS code-writer --status completed
```

### Step 3: Spawn Tester Teammate

Spawn tester teammate (sonnet):

```
You are the "tester" teammate for Jira ticket $ARGUMENTS.

MANDATORY OUTPUT — THIS IS YOUR #1 PRIORITY:
You MUST write `memory/tickets/$ARGUMENTS/test-results.json` before finishing.
Even if the test crashes, you MUST still write this file with status "failed" and the error.

INSTRUCTIONS:
1. Read `.claude/agents/test-runner-agent.md` for execution instructions.
2. Read memory/tickets/$ARGUMENTS/implementation.md for test file location.

TEST EXECUTION:
- cd framework/
- Run: envFile=.env.<target_env> npx playwright test <testName>.test --reporter=list
- Capture full output (stdout + stderr)
- Parse results: count passed, failed, skipped
- For each failure: extract test name, error message, expected vs actual

OUTPUT:
Write to memory/tickets/$ARGUMENTS/test-results.json (use EXACT field names):
{
    "status": "passed|failed",
    "total": <N>,
    "passed": <N>,
    "failed": <N>,
    "skipped": <N>,
    "duration_ms": <N>,
    "test_file": "<path>",
    "failures": [
        {
            "test_name": "#3 Verify feature",
            "error": "expect(received).toBe(expected)",
            "error_type": "assertion_failure|selector_not_found|timeout|syntax_error",
            "expected": "<value>",
            "actual": "<value>",
            "line": <N>,
            "trace_path": "test-results/<trace-folder>/trace.zip"
        }
    ],
    "traces": ["test-results/<trace-folder>/trace.zip"]
}

Update checkpoint: add "test-runner" to completed_stages.

IMPLEMENTATION CONTEXT:
<paste implementation.md>
```

Wait for tester to complete.

**DASHBOARD REPORT (MANDATORY — EXECUTE BEFORE PROCEEDING TO NEXT PHASE):**
```bash
./scripts/report-to-dashboard.sh $ARGUMENTS test-runner --status completed
```

### Step 4: Debug Loop (if tests failed, max 3 cycles)

If `test-results.json` shows `status: "failed"`:

For each debug cycle (N = 1, 2, 3):

Spawn developer teammate (opus) for debug:

```
You are the "developer" teammate for Jira ticket $ARGUMENTS (debug cycle <N>/3).

YOUR TASK: Fix failing tests and verify the fix.

DO NOT read any agent .md files. All instructions are below.

STEP 1 — ANALYZE: Read memory/tickets/$ARGUMENTS/test-results.json for failures.
If cycle 2+, also read memory/tickets/$ARGUMENTS/debug-history.md.

STEP 2 — ANALYZE TRACES FIRST (before opening a browser):

    cd $E2E_FRAMEWORK_PATH
    find test-results/ -name "trace.zip" 2>/dev/null
    mkdir -p /tmp/trace-debug && unzip -o <trace-path> -d /tmp/trace-debug 2>/dev/null
    cat /tmp/trace-debug/*.har 2>/dev/null | python3 -c "
    import json, sys
    har = json.load(sys.stdin)
    for entry in har['log']['entries'][-20:]:
        print(f\"{entry['response']['status']} {entry['request']['url'][:100]}\")
    " 2>/dev/null || true

STEP 3 — IF TRACE IS INSUFFICIENT, use playwright-cli (NEVER raw node scripts):

    playwright-cli open "$STAGING_URL"
    playwright-cli fill "input[name='email'],input[type='email']" "$STAGING_USER"
    playwright-cli fill "input[name='password'],input[type='password']" "$STAGING_PASSWORD"
    playwright-cli click "button[type='submit']"
    playwright-cli goto "<target-page-url>"
    playwright-cli snapshot
    playwright-cli screenshot

    NEVER use `node -e` with Playwright API. ALWAYS use playwright-cli commands.
    playwright-cli is already installed globally. Do NOT run npm install.

COMMON FAILURE PATTERNS:
- Selector not found: check trace DOM snapshot first, then playwright-cli snapshot
- Timeout: check trace network log, add explicit waitForSelector (NEVER networkidle)
- Assertion mismatch: check trace for actual values, verify with playwright-cli
- Navigation error: verify URL path, check if page requires different navigation

STEP 4 — FIX the code (test file, action, or selector).

STEP 5 — COMMIT:

    cd $E2E_FRAMEWORK_PATH
    git add <fixed-files>
    git commit -m "$ARGUMENTS: Fix <description> (debug cycle <N>)"

STEP 6 — RE-RUN (always --retries=0 --trace on):

    cd $E2E_FRAMEWORK_PATH && envFile=.env.stg npx playwright test <test-file> --retries=0 --trace on

If pass: commit fix, update output files.
If fail: document what was tried and why it failed.

OUTPUT (MANDATORY):
- Overwrite memory/tickets/$ARGUMENTS/test-results.json with EXACT fields: "status", "total", "passed", "failed", "duration_ms" (in milliseconds), "debug_cycles" (number of cycles used), "test_file", "traces"
- Write/update memory/tickets/$ARGUMENTS/debug-output.json with per-cycle structured data (REQUIRED — dashboard depends on this)
- Append to memory/tickets/$ARGUMENTS/debug-history.md
- Update checkpoint: increment debug_cycles

NEVER modify: setHooks.js, playwright.config.js, params/global.json

FAILURE CONTEXT:
<paste test-results.json + implementation.md + debug-history.md>
```

Wait for debug to complete.

**DASHBOARD REPORT (MANDATORY — EXECUTE BEFORE PROCEEDING TO NEXT PHASE):**
```bash
./scripts/report-to-dashboard.sh $ARGUMENTS debug --status cycle_<N>
```

**Cycle outcome:**
- If PASS: exit debug loop, update checkpoint, proceed
- If FAIL and N < 3: start next cycle
- If FAIL and N = 3: stop, add `ai-failed` label, report failure

### Step 5: Cleanup

Shut down all teammates and delete team `qa-impl-$ARGUMENTS`.

## Arguments

- `$ARGUMENTS` -- the Jira ticket key, optionally followed by flags (e.g., `OXDEV-123` or `OXDEV-123 --auto`)
- `--auto` -- skip plan approval, run fully unattended
