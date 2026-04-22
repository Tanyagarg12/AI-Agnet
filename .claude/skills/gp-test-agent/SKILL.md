---
name: gp-test-agent
description: >
  Full autonomous test automation pipeline for any ticket platform and framework.
  Reads a ticket, analyzes requirements, scaffolds the test project, explores the
  UI (optional), generates test code following POM best practices, runs tests,
  generates reports, debugs failures (up to 3 cycles), and creates a PR/MR.
argument-hint: "<ticket-url-or-key> [--platform jira|github|ado|linear|servicenow] [--framework playwright-js|playwright-ts|playwright-python|selenium-python|selenium-java|cypress-js|appium-python|appium-java|robot-framework] [--vcs github|gitlab|azure-repos] [--language js|ts|python|java|csharp] [--project-path /abs/path] [--env staging|dev|prod] [--auto] [--no-browse] [--no-pr] [--debug-only] [--resume]"
---

# GP Test Agent — Full Autonomous Pipeline

You are the lead orchestrator of the General-Purpose (GP) test automation pipeline. Your goal is to take a ticket ID or URL from any platform and produce a fully implemented, passing test suite with a merge/pull request.

## Pipeline Stages

```
intake → plan → scaffold → [browse] → codegen → run → report → [debug×3] → pr → learn
```

## Step 0: Parse Arguments & Initialize

**FIRST**: Load environment variables from `.env`:
```bash
source .env 2>/dev/null || true
```
This ensures JIRA_BASE_URL, JIRA_USER, JIRA_TOKEN, GH_TOKEN, GH_REPO and other credentials are available. If `source .env` produces empty vars, read the `.env` file directly and extract values.

Parse the arguments provided to this skill:

```
TICKET_INPUT = first positional argument (URL or key)
FLAGS:
  --platform      → override auto-detected platform
  --framework     → override auto-detected or selected framework
  --vcs           → override auto-detected VCS provider
  --language      → override framework default language
  --project-path  → absolute path to test project (default: GP_TEST_PROJECT_PATH env)
  --env           → target environment (default: staging)
  --auto          → skip interactive plan approval, run fully unattended
  --no-browse     → skip UI browser exploration (use ticket description only)
  --no-pr         → generate code but do not create PR/MR
  --debug-only    → only run the debug cycle on existing run-results.json
  --resume        → resume from checkpoint if previous run exists
```

Generate a unique RUN-ID:

```
RUN_ID="GP-$(date +%Y%m%d-%H%M%S)"
MEMORY_DIR="memory/gp-runs/${RUN_ID}"
mkdir -p "${MEMORY_DIR}"
```

Write skeleton checkpoint:

```json
{
  "run_id": "<RUN_ID>",
  "ticket_input": "<TICKET_INPUT>",
  "pipeline": [
    "intake",
    "plan",
    "scaffold",
    "browse",
    "codegen",
    "run",
    "report",
    "debug",
    "pr",
    "learn"
  ],
  "completed_stages": [],
  "current_stage": "intake",
  "status": "in_progress",
  "flags": {},
  "last_updated": "<ISO_TIMESTAMP>"
}
```

If `--resume` flag present: read existing checkpoint, skip completed stages.

Load defaults:

```bash
cat config/gp-defaults.json
```

Load environment variables:

```bash
set -a
source .env 2>/dev/null || true
set +a
```

## Step 1: INTAKE — Read Ticket from Any Platform

The lead agent should perform the intake directly (faster than delegating for a simple API call).

### Jira Tickets (key matches `[A-Z]+-[0-9]+`)

**ALWAYS** use `jira-curl.sh` for Jira API calls — it handles DNS resolution failures automatically:

```bash
# Fetch ticket — this handles DNS issues via Google DNS fallback
TICKET_JSON=$(bash scripts/jira-curl.sh "/rest/api/2/issue/${TICKET_ID}?expand=renderedFields")
```

**NEVER** use raw `curl -sf -u ...` for Jira. The user's network has DNS issues that `jira-curl.sh` works around.

Save raw response, then extract fields:
- `title` from `fields.summary`
- `description` from `fields.description`
- `type` from `fields.issuetype.name`
- `priority` from `fields.priority.name`
- `status` from `fields.status.name`
- `acceptance_criteria` from description sections or `customfield_10016`

### Other Platforms

For GitHub Issues, Azure DevOps, Linear, ServiceNow — delegate to `gp-intake-agent`.

### Context to pass to agent (if delegating):

- `ticket_input`: the raw ticket URL or key
- `run_id`: the generated RUN-ID
- `platform_override`: value of `--platform` flag (may be null)
- `memory_dir`: path to per-run memory directory

### Write intake.json

Write `memory/gp-runs/<RUN_ID>/intake.json` with normalized ticket data.

**After intake**: Read the summary from `intake.json` and display to user:

```
✅ Ticket Read: [TICKET_ID] - [TITLE]
   Platform: [PLATFORM]
   Type: [TYPE] | Priority: [PRIORITY]
   Acceptance Criteria: [COUNT] items
```

Update checkpoint: `completed_stages += ["intake"]`

## Step 2: PLAN — Analyze Requirements & Select Framework

**Delegate to agent**: `gp-planner-agent`
**Context to pass**:

- `run_id`
- `framework_override`: value of `--framework` flag
- `vcs_override`: value of `--vcs` flag
- `project_path`: value of `--project-path` flag (or `${GP_TEST_PROJECT_PATH}`)
- `env`: value of `--env` flag
- `no_browse`: boolean

**What the agent does**:

1. Reads `intake.json` and `memory/gp/platform-patterns.md`
2. Classifies ticket: UI, API, mobile, or mixed
3. If `--framework` provided: load that framework config
4. If not provided: auto-detect by scanning project files OR present selection menu to user
5. Decomposes acceptance criteria into atomic test steps
6. Identifies POM page classes needed
7. Identifies reusable helper functions needed
8. Plans selector strategy based on framework config
9. Writes `memory/gp-runs/<RUN_ID>/plan.json`

**Framework Selection Menu** (shown when not auto-detected and `--auto` not set):

```
Select a testing framework:
  1. Playwright (JavaScript)    [playwright-js]
  2. Playwright (TypeScript)    [playwright-typescript]
  3. Playwright (Python)        [playwright-python]
  4. Selenium (Python)          [selenium-python]
  5. Selenium (Java)            [selenium-java]
  6. Cypress (JavaScript)       [cypress-js]
  7. Appium (Python) - Mobile   [appium-python]
  8. Appium (Java) - Mobile     [appium-java]
  9. Robot Framework            [robot-framework]

Enter number or framework ID:
```

**Plan Display** (shown before proceeding unless `--auto`):

```
📋 Test Plan: [TICKET_ID]
   Framework: [FRAMEWORK]    Language: [LANGUAGE]    VCS: [VCS]
   Project:   [PROJECT_PATH]

   Test Scenarios ([COUNT]):
     1. [SCENARIO_1]
     2. [SCENARIO_2]
     ...

   POM Pages Needed: [PAGE_LIST]
   Helper Functions: [HELPER_LIST]
   Test Steps: [COUNT]

   Proceed? (y/n):
```

If `--auto`: skip prompt, proceed automatically.

Update checkpoint: `completed_stages += ["plan"]`

## Step 3: SCAFFOLD — Set Up Project Structure

**Delegate to agent**: `gp-scaffolder-agent`

**What the agent does**:

1. Reads `plan.json` and `config/frameworks/<framework>.json`
2. Checks if project path exists:
   - If exists: detect existing structure, skip conflicting files
   - If not exists: create full directory structure from framework config
3. Creates config files (playwright.config.js, pytest.ini, pom.xml, etc.)
4. Creates POM skeleton files (BasePage, BaseTest)
5. Creates selectors config file (`config/selectors/<feature>.json`)
6. Installs dependencies (npm/pip/mvn) from framework `install_commands`
7. Sets up reporting (Allure or HTML) per framework config
8. Creates git branch: `test/<ticket_id>-<slug>`
9. Makes initial commit: "chore: scaffold test project for <TICKET_ID>"
10. Writes `memory/gp-runs/<RUN_ID>/scaffold.json`

Update checkpoint: `completed_stages += ["scaffold"]`

## Step 4: BROWSE — Explore UI (Optional)

Skip if `--no-browse` flag set OR if test scope is `api` or `mobile`.

**Delegate to agent**: `gp-browser-agent`

**What the agent does**:

1. Reads `plan.json` for target pages and app URL
2. Uses Chrome CDP or playwright-cli to navigate the application
3. Captures element selectors for all interactive elements
4. Takes screenshots of target pages
5. Documents navigation flow (URL changes, redirects)
6. Captures network requests for API-heavy pages
7. Writes `memory/gp-runs/<RUN_ID>/browser-data.json` in framework-agnostic format

Update checkpoint: `completed_stages += ["browse"]`

## Step 5: CODEGEN — Generate Test Code

**Delegate to agent**: `gp-codegen-agent`

**What the agent does**:

1. Reads `plan.json`, `scaffold.json`, `browser-data.json`
2. Loads `templates/gp/codegen/<framework>.md` for language-specific conventions
3. Loads `templates/gp/pom/<language>.md` for POM class pattern
4. Reads `memory/gp/framework-patterns.md` for known best practices
5. Generates in this order (each committed separately):
   a. **Selectors file**: `config/selectors/<feature>.json` — all XPath/CSS/testid selectors
   b. **POM page classes**: `pages/LoginPage.{ext}`, etc. — each as separate commit
   c. **Helper functions**: `helpers/<feature>Helper.{ext}` — reusable actions
   d. **Test file**: `tests/<feature>.spec.{ext}` — calls POM methods
6. Every expect/assertion MUST include a descriptive failure message
7. Config values (URLs, credentials) ALWAYS from env vars, NEVER hardcoded
8. Writes `memory/gp-runs/<RUN_ID>/codegen.json` with git diff

Update checkpoint: `completed_stages += ["codegen"]`

## Step 6: RUN — Execute Tests

**Delegate to agent**: `gp-runner-agent`

**What the agent does**:

1. Reads `codegen.json` for test file path
2. Reads `config/frameworks/<framework>.json` for run command
3. Executes: `./scripts/gp-run-tests.sh <RUN_ID> <TEST_FILE>`
4. Parses results via `./scripts/gp-parse-results.sh <RUN_ID>`
5. Writes `memory/gp-runs/<RUN_ID>/run-results.json`

Display result summary:

```
🧪 Test Results: [TICKET_ID]
   Total: [N]  ✅ Passed: [N]  ❌ Failed: [N]  ⏭ Skipped: [N]
   Duration: [Xs]
```

Update checkpoint: `completed_stages += ["run"]`

## Step 7: REPORT — Generate Test Report

**Delegate to agent**: `gp-reporter-agent`

**What the agent does**:

1. Generates Allure report (if configured): `allure generate allure-results -o allure-report`
2. Generates HTML report (if configured): framework-specific command
3. Captures screenshots of failure states
4. Writes `memory/gp-runs/<RUN_ID>/report.json` with report paths

Update checkpoint: `completed_stages += ["report"]`

## Step 8: DEBUG — Fix Failures (Conditional, Max 3 Cycles)

Skip if: all tests passed OR `--no-pr` flag and no debug needed.

**Delegate to agent**: `gp-debugger-agent`
**Cycle limit**: 3 stalled cycles (progress resets counter)

**What the agent does per cycle**:

1. Reads `run-results.json` failures
2. Classifies failure type: `selector_not_found | assertion_failure | timeout | syntax_error | auth_failure | network_error`
3. Checks `memory/gp/failure-catalog.md` for known similar failures → apply known fix first
4. If selector failure: re-inspect live DOM via CDP/playwright-cli
5. If assertion failure: re-read acceptance criteria, fix expected value
6. If timeout: add appropriate wait strategies
7. Fixes code, commits, re-runs tests
8. Appends to `memory/gp-runs/<RUN_ID>/debug-history.md`
9. Overwrites `run-results.json` with new results

After max cycles with remaining failures:

- Do NOT create PR
- Add failure summary to audit log
- Instruct user to review `debug-history.md`

Update checkpoint: `completed_stages += ["debug"]`

## Step 9: PR — Create Pull/Merge Request

Skip if `--no-pr` flag OR if tests still failing after debug.

**Delegate to agent**: `gp-pr-agent`

**What the agent does**:

1. Reads `vcs/<vcs>.json` for provider commands
2. Verifies: branch has commits, tests are passing
3. Pushes branch: `git push -u origin <branch>`
4. Creates PR/MR using platform CLI
5. Adds ticket reference in PR description
6. Comments on original ticket with PR link (if platform supports it)
7. Writes `memory/gp-runs/<RUN_ID>/pr-result.json`

Display result:

```
🔀 Pull Request Created:
   [PR_URL]
   Branch: test/<ticket_id>-<slug> → <target_branch>
```

Update checkpoint: `completed_stages += ["pr"]`

## Step 10: LEARN — Extract Learnings

Always runs as the final step.

**Delegate to agent**: `gp-learner-agent`

**What the agent does**:

1. Reviews all stage outputs for this run
2. Extracts platform-specific learnings → appends to `memory/gp/platform-patterns.md`
3. Extracts framework-specific learnings → appends to `memory/gp/framework-patterns.md`
4. Indexes any debug fixes → appends to `memory/gp/failure-catalog.md`
5. Appends VCS patterns → `memory/gp/vcs-patterns.md`

Update checkpoint: `status = "completed"`, `completed_stages += ["learn"]`

## Final Summary

Display to user:

```
✅ Pipeline Complete: [RUN_ID]
   Ticket: [TICKET_ID] - [TITLE]
   Framework: [FRAMEWORK]
   Tests: [PASSED]/[TOTAL] passing
   PR: [PR_URL]
   Report: [REPORT_PATH]
   Duration: [TOTAL_TIME]
```

## Error Handling

- Each stage writes its outputs BEFORE doing complex work (skeleton-first pattern)
- If a stage fails: update checkpoint with error, stop pipeline, display actionable message
- Use `--resume` flag to continue from last successful checkpoint
- All errors appended to `memory/gp-runs/<RUN_ID>/audit.md`

## Important Rules

- NEVER hardcode credentials, URLs, or environment-specific values in generated test code
- NEVER modify files in `config/platforms/`, `config/frameworks/`, `config/vcs/`
- NEVER push to protected branches: main, master, develop, release/_, hotfix/_
- ALWAYS commit in logical units (selectors → POM → helpers → tests)
- ALWAYS include descriptive assertion messages in every expect() call
- ALWAYS use env vars for configuration (URLs, credentials, timeouts)
- ALWAYS follow POM pattern — no direct selector usage in test files
