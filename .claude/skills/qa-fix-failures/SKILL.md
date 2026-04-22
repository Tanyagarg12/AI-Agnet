---
name: qa-fix-failures
description: Fetch test failures from the timeline-dashboard, diagnose automation issues, and auto-fix them. Creates fix branches with MRs targeting developmentV2.
disable-model-invocation: true
argument-hint: "[--folder Staging|Dev|Prod] [--job <name>] [--env dev|stg] [--category <cat>]"
---

# Auto-Fix Pipeline: Fix Failing Tests from Dashboard

Fetch categorized test failures from the timeline-dashboard API, diagnose automation issues (broken selectors, timing, flow changes, assertion mismatches), and automatically fix them. Creates fix branches with MRs.

## Usage

```
/qa-fix-failures                              # fetch automation_issue failures from Dev, show list
/qa-fix-failures --folder Stg                 # filter by Stg folder
/qa-fix-failures --job settingsExclude        # fix specific job (partial match)
/qa-fix-failures --env dev                    # target dev environment for test runs
/qa-fix-failures --category possible_real_issue  # fix a different category
```

## Flags

Parse `$ARGUMENTS` for flags before processing:
- **`--folder <folder>`**: Jenkins folder to query (default: `Staging`). Options: `Staging`, `Dev`, `Prod`. Aliases: `Stg`→`Staging`.
- **`--view <view>`**: Jenkins view (default: `AA_Release`).
- **`--job <name>`**: Filter to a specific job by partial name match. Skips the selection prompt.
- **`--env stg|dev`**: Target environment for test execution (default: `stg`). Maps to `envFile=.env.stg` or `.env.dev`.
- **`--category <cat>`**: Failure category to fetch (default: `automation_issue`). Options: `automation_issue`, `possible_real_issue`, `environment_failure`.

Extract flags from `$ARGUMENTS`. For example, `--folder Stg --job settings --env dev` means: query Stg folder, filter jobs containing "settings", run tests against dev.

---

## Phase 1: Fetch Failures from Dashboard

Run the fetcher script to get categorized failures:

```bash
bash scripts/fetch-dashboard-failures.sh \
  --folder <folder> --view <view> --category <category> \
  --output memory/tickets/FIX-dashboard/dashboard-failures.json \
  $([ -n "<job_filter>" ] && echo "--job <job_filter>")
```

Read the output JSON. If `matched_count == 0`:
- Report: "No **<category>** failures found in **<folder>/<view>**."
- Exit.

### Present Selection

If `--job` was NOT specified (or matched multiple jobs), present a numbered table:

```
Automation Issues (Dev / AA_Release):

 #  | Job Name                      | Reason (truncated)                    | Confidence
 1  | settingsExcludeSecretPII      | Selector //button[...] not found      | 92%
 2  | issuesV2FiltersScan           | Timeout on navigation after scan      | 87%
 3  | API_Dashboard_page_tests      | Login check failed: locator timeout   | 90%

Enter a number to fix, or 'q' to quit:
```

Wait for user selection via a question. If `--job` matched exactly one job, auto-select it and inform the user.

Store the selected failure as `$SELECTED_FAILURE` (the JSON object from the failures array).

---

## Phase 2: Identify Test File

The fetcher script provides a `test_file_guess` field, but it may be null. Resolve the actual test file:

1. If `test_file_guess` is set, verify it exists:
   ```bash
   ls "$E2E_FRAMEWORK_PATH/$test_file_guess" 2>/dev/null
   ```

2. If not found, search by job name patterns:
   ```bash
   # Strip prefixes and search
   JOB_CLEAN=$(echo "$JOB_NAME" | sed 's/^_[0-9]*_[0-9]*_//; s/^API_//')
   find "$E2E_FRAMEWORK_PATH/tests" -name "*${JOB_CLEAN}*" -name "*.test.js" 2>/dev/null
   ```

3. If still not found, try broader fuzzy match:
   ```bash
   # Split by underscore and search for longest matching substring
   find "$E2E_FRAMEWORK_PATH/tests" -name "*.test.js" | xargs grep -l "<relevant keyword from reason>" 2>/dev/null | head -5
   ```

4. If no test file can be identified:
   - Report: "Could not find test file for job '<job_name>'. Please provide the test file path."
   - Ask user with AskUserQuestion for the test file path.
   - If user can't provide one, exit.

Store as `$TEST_FILE` (path relative to `$E2E_FRAMEWORK_PATH`).

---

## Phase 3: Pre-Inspection (Lead Quick-Fix Attempt)

Before spawning expensive agents, the lead attempts a quick diagnosis:

### 3.1 Read the Test Structure

```bash
cd $E2E_FRAMEWORK_PATH
# Find which selector file the test imports
grep -oP "require\([\"'].*?selectors/(.*?)[\"']\)" "$TEST_FILE" | head -5
# Find which action files the test imports
grep -oP "require\([\"'].*?actions/(.*?)[\"']\)" "$TEST_FILE" | head -5
```

Read the test file, its selector JSON, and action files to understand the structure.

### 3.2 Analyze the Error

From `$SELECTED_FAILURE`, extract:
- `reason`: The raw error message
- `explanation`: AI-generated explanation of the failure
- `suggested_action`: AI-generated fix suggestion

Classify the error type:
- **selector_not_found**: reason contains "locator", "Timeout.*selector", "not found", "not visible"
- **assertion_failure**: reason contains "expect", "toBe", "toContain", "assertion"
- **timeout**: reason contains "Timeout", "navigation timeout", "waiting"
- **syntax_error**: reason contains "TypeError", "ReferenceError", "SyntaxError", "Cannot read properties"
- **auth_failure**: reason contains "login", "401", "unauthorized", "API key"

### 3.3 Quick Fix Attempt (Selector Issues Only)

If error type is `selector_not_found` AND the failing selector can be extracted from the error message:

1. Detect available browser tool (3-tier priority):

   **Tier 0 — `claude-in-chrome` MCP tools (preferred, lead agent only):**
   The lead runs in the main Claude Code session and has access to `mcp__claude-in-chrome__*` tools when Chrome extension is connected. These share the user's browser login state (no programmatic login needed) and support natural-language element search.

   Check availability by calling `mcp__claude-in-chrome__tabs_context_mcp`. If it returns tabs, use `claude-in-chrome`. If it errors with "No Chrome extension connected", fall through to Tier 1.

   **Tier 1 — Chrome CDP:**
   ```bash
   CDP="node .claude/skills/chrome-cdp/scripts/cdp.mjs"
   if $CDP list 2>/dev/null; then
       BROWSER_TOOL="cdp"
   else
       echo "CDP unavailable — using playwright-cli"
       BROWSER_TOOL="playwright-cli"
   fi
   ```

   **Tier 2 — playwright-cli (always works).**

2. Navigate to the page and inspect:

   **If using `claude-in-chrome` (Tier 0):**
   ```
   # Get or create a tab
   mcp__claude-in-chrome__tabs_context_mcp
   mcp__claude-in-chrome__tabs_create_mcp  # if no usable tab
   mcp__claude-in-chrome__navigate(tabId=<id>, url="<app-url>/<page-path>")

   # Search for the failing element by description (natural language!)
   mcp__claude-in-chrome__find(tabId=<id>, query="<description of element from error>")

   # Get full accessibility tree for the area
   mcp__claude-in-chrome__read_page(tabId=<id>, filter="all")

   # Or run JS to enumerate data-testid attributes
   mcp__claude-in-chrome__javascript_tool(tabId=<id>, action="javascript_exec",
       text="[...document.querySelectorAll('[data-testid]')].map(e => ({testid: e.dataset.testid, tag: e.tagName, text: e.textContent.trim().slice(0,50)}))")
   ```

   No login needed — shares the user's existing Chrome session.

   **If `BROWSER_TOOL=cdp` (Tier 1):**
   ```bash
   $CDP snap <target>  # Get accessibility tree
   ```

   **If `BROWSER_TOOL=playwright-cli` (Tier 2):**
   ```bash
   SESSION="fix-$(echo $JOB_NAME | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')"
   playwright-cli -s=$SESSION open "$APP_URL"
   # Login via snapshot refs...
   playwright-cli -s=$SESSION goto "<page-url>"
   playwright-cli -s=$SESSION snapshot  # Get element refs and DOM structure
   ```

3. Search the snapshot for the element using alternative attributes (data-testid, text, role).

4. If a new selector is found with high confidence:
   - Update the selector in the JSON file
   - Create fix branch and commit:
     ```bash
     cd $E2E_FRAMEWORK_PATH
     git fetch origin developmentV2
     git checkout -b fix/maintenance-<job-name> origin/developmentV2
     # Edit selector file
     git add <selector-file>
     git commit -m "fix(selectors): update <selector-key> for <test-name>"
     ```
   - Run the test to verify:
     ```bash
     cd $E2E_FRAMEWORK_PATH
     envFile=.env.<env> npx playwright test "$TEST_FILE" --retries=0 --trace on
     ```
   - If test passes → skip to Phase 6 (MR creation)
   - If test fails → continue to Phase 4 (full debug pipeline)

If CDP is not available or the fix is not trivial, proceed to Phase 4.

---

## Phase 4: Setup Working Directory

Create the memory structure and branch:

```bash
# Memory directory
TICKET_KEY="FIX-$(echo "$JOB_NAME" | sed 's/[^a-zA-Z0-9]/-/g')"
mkdir -p memory/tickets/$TICKET_KEY

# Checkpoint
cat > memory/tickets/$TICKET_KEY/checkpoint.json << EOF
{
    "ticket_key": "$TICKET_KEY",
    "pipeline": "fix-failures",
    "completed_stages": ["fetch"],
    "current_stage": "explore",
    "status": "in_progress",
    "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "debug_cycles": 0,
    "branch_name": "fix/maintenance-$(echo "$JOB_NAME" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]')",
    "stage_outputs": {
        "fetch": "memory/tickets/$TICKET_KEY/dashboard-failure.json"
    },
    "error": null
}
EOF

# Save selected failure data
# (write the selected failure JSON to dashboard-failure.json)

# Create fix branch (if not already created in Phase 3)
cd $E2E_FRAMEWORK_PATH
git fetch origin developmentV2
git checkout -b "fix/maintenance-$(echo "$JOB_NAME" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]')" origin/developmentV2

# Audit log
cat >> memory/tickets/$TICKET_KEY/audit.md << EOF
### [$(date -u +%Y-%m-%dT%H:%M:%SZ)] fix-pipeline-lead
- **Action**: pipeline:start
- **Target**: $TICKET_KEY
- **Result**: success
- **Details**: Fix pipeline started for job $JOB_NAME (build #$BUILD_NUMBER), category: $CATEGORY
EOF
```

---

## Phase 5: Explore + Debug (Spawn Agents)

### 5.1 Spawn Explorer (Sonnet, 15 turns)

Spawn an explorer teammate to gather framework context:

**Prompt for explorer:**
> You are exploring the E2E framework to gather context for fixing a failing test.
>
> **Test file**: `<TEST_FILE>`
> **Job name**: `<JOB_NAME>`
> **Error**: `<REASON>`
> **Dashboard explanation**: `<EXPLANATION>`
> **Suggested action**: `<SUGGESTED_ACTION>`
>
> Your task:
> 1. Read the test file and understand its structure (test steps, selectors, actions used)
> 2. Read the selector JSON file(s) imported by this test
> 3. Read the action file(s) imported by this test
> 4. Identify which selectors/actions are most likely related to the failure
> 5. Check if similar tests exist that handle the same page/feature (for reference patterns)
> 6. Write your findings to `memory/tickets/<TICKET_KEY>/exploration.md`
>
> Framework path: `$E2E_FRAMEWORK_PATH`
> Ticket key: `<TICKET_KEY>`

Wait for explorer to complete. Read `exploration.md`.

### 5.2 Create Synthetic test-results.json

Before spawning the debug agent, create the test-results file it expects:

```bash
cat > memory/tickets/$TICKET_KEY/test-results.json << 'JSONEOF'
{
    "status": "failed",
    "total": 1,
    "passed": 0,
    "failed": 1,
    "skipped": 0,
    "duration": 0,
    "test_file": "<TEST_FILE>",
    "failures": [
        {
            "test_name": "<JOB_NAME>",
            "error": "<REASON>",
            "error_type": "<CLASSIFIED_ERROR_TYPE>",
            "expected": null,
            "actual": null,
            "line": null,
            "trace_path": null,
            "dashboard_context": {
                "category": "<CATEGORY>",
                "confidence": <CONFIDENCE>,
                "explanation": "<EXPLANATION>",
                "suggested_action": "<SUGGESTED_ACTION>",
                "log_chunk": "<LOG_CHUNK>",
                "org_name": "<ORG_NAME>"
            }
        }
    ]
}
JSONEOF
```

### 5.3 Spawn Debug Agent (Opus, 40 turns)

Spawn the debug agent with modified instructions:

**Prompt for debug agent:**
> You are the Debug Agent for the fix-failures pipeline. You are fixing an existing test that has been failing in Jenkins.
>
> **CRITICAL DIFFERENCE FROM NORMAL PIPELINE**: Skip Phase 1 (waiting for test results). The file `memory/tickets/<TICKET_KEY>/test-results.json` already contains failure data fetched from the timeline-dashboard. Start directly at Phase 2 (analyze and fix).
>
> **Dashboard Context**: The `dashboard_context` field in each failure contains pre-classified error information from the dashboard's AI categorization. Use the `explanation` and `suggested_action` fields to guide your investigation — they contain useful diagnostic hints.
>
> **Test file**: `<TEST_FILE>` (in `$E2E_FRAMEWORK_PATH`)
> **Branch**: `<BRANCH_NAME>` (already checked out)
> **Ticket key**: `<TICKET_KEY>`
> **Environment**: `<ENV>` (use `envFile=.env.<env>` when running tests)
>
> **Framework context** (from explorer):
> <paste exploration.md content or key excerpts>
>
> Follow all standard debug agent rules: max 3 cycles, commit each fix, use `--retries=0 --trace on`, update test-results.json and debug-history.md after each cycle.

Wait for debug agent to complete.

---

## Phase 6: Evaluate Results + Create MR

Read `memory/tickets/$TICKET_KEY/test-results.json` for final status.

### If PASSED:

1. **Flaky check** (skip if test has scan steps):
   ```bash
   grep -l "triggerFullScanAndWait\|triggerScan\|runScan\|scanTimeOut\|findDoc\|replaceDoc\|updateCritical" "$E2E_FRAMEWORK_PATH/$TEST_FILE" 2>/dev/null
   ```
   If no match → run the test one more time for confidence:
   ```bash
   cd $E2E_FRAMEWORK_PATH
   envFile=.env.<env> npx playwright test "$TEST_FILE" --retries=0 --trace on
   ```

2. **Create MR**:
   ```bash
   cd $E2E_FRAMEWORK_PATH
   git push -u origin "$BRANCH_NAME"
   glab mr create \
     --target-branch developmentV2 \
     --title "fix: $JOB_NAME - $ERROR_TYPE" \
     --description "$(cat <<'EOF'
   ## Auto-Fix: Test Maintenance

   **Job**: <JOB_NAME>
   **Build**: #<BUILD_NUMBER>
   **Category**: <CATEGORY> (confidence: <CONFIDENCE>%)
   **Error**: <REASON>

   ### Fix Applied
   <summary from debug-history.md>

   ### Debug Cycles
   <N> cycle(s) used

   ### Files Changed
   <list from git diff>

   ---
   Generated by `/qa-fix-failures` pipeline
   EOF
   )"
   ```

3. **Update checkpoint**:
   ```json
   {
     "status": "completed",
     "completed_stages": ["fetch", "explore", "debug", "mr"],
     "current_stage": "done"
   }
   ```

### If FAILED (after 3 debug cycles):

1. Log failure details to audit.md
2. Update checkpoint with `"status": "failed"`
3. Report to user:
   ```
   Fix FAILED for <JOB_NAME> after 3 debug cycles.

   Last error: <error from test-results.json>
   Debug history: memory/tickets/<TICKET_KEY>/debug-history.md
   Branch: <BRANCH_NAME> (changes are on the branch for manual review)
   ```

---

## Phase 7: Report + Cleanup

1. **Dashboard report**:
   ```bash
   ./scripts/report-to-dashboard.sh "$TICKET_KEY" debug --status completed
   ```

2. **Present summary**:
   ```
   Fix Pipeline Results:
   Job: <JOB_NAME> (build #<BUILD_NUMBER>)
   Category: <CATEGORY>
   Status: FIXED / FAILED
   Debug cycles: <N>
   Branch: <BRANCH_NAME>
   MR: <MR_URL or "none">
   Files changed: <list>
   ```

3. **Cleanup on success**: Return to agent repo directory:
   ```bash
   cd $PROJECT_ROOT
   ```

---

## Error Handling

- **Dashboard unreachable**: Report error with the URL attempted and exit
- **No E2E_FRAMEWORK_PATH**: Report "E2E_FRAMEWORK_PATH not set" and exit
- **Test file not found**: Ask user for path, exit if not provided
- **Git checkout fails**: Report error, try `git stash` + retry once
- **Debug agent exhausts turns**: Lead reads debug-history.md and writes fallback output
- **Protected file modification**: Framework safety hooks block this automatically

## Safety Rules

- All standard framework safety rules apply (protected files, banned patterns)
- Maximum 3 debug cycles per fix attempt
- Branch naming: `fix/maintenance-<job-name>` (lowercase, hyphens)
- MR target: `developmentV2` only
- Never modify `playwright.config.js`, `utils/setHooks.js`, `params/global.json`
- Never use `page.waitForLoadState("networkidle")`
