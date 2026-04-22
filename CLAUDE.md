# QA E2E Autonomous Test Agent

Autonomous Jira-to-test pipeline using Claude Code Agent Teams. Takes a Jira ticket describing a new Playwright E2E test and produces a fully implemented, passing test with a merge request. Can also auto-discover testable changes from GitLab MRs and create Jira tickets.

## Architecture

### Implementation Pipeline (7 agents)

| Agent | Model | Turns | Purpose |
|-------|-------|-------|---------|
| triage | Haiku | 10 | Classify ticket, identify feature area, complexity |
| explorer | Sonnet | 25 | Explore E2E framework patterns, find similar tests |
| playwright | Sonnet | 40 | Open browser via Playwright CLI, gather locators/values/screenshots |
| code-writer | Opus | 50 | Write test file, action functions, selector JSON |
| test-runner | Sonnet | 15 | Execute test, parse results |
| debug | Opus | 40 | Analyze failures, re-inspect, fix code (max 3 stalled cycles) |
| pr | Haiku | 10 | Create MR to developmentV2 |
| validator | Haiku | 15 | Validate output + quality checklist |
| retrospective | Haiku | 10 | Extract cross-ticket learnings |

### Discovery Pipeline (3 agents)

| Agent | Model | Turns | Purpose |
|-------|-------|-------|---------|
| scanner | Haiku | 10 | Scan GitLab for merged MRs, extract OXDEV ticket refs |
| analyzer | Sonnet | 25 | Classify changes, validate Jira-MR alignment, group into scenarios |
| ticket-creator | Opus | 15 | Create OXDEV Jira tickets with QA instructions |

### Monitored Services

| Service | GitLab Project ID | Description |
|---------|-------------------|-------------|
| frontend | 30407646 | Main OX Security web application |
| connectors | 30667022 | Integration connectors service |
| settings-service | 43885247 | Application settings service |
| report-service | 30966426 | Report generation service |
| gateway | (discover via API) | API gateway / BFF |

## Skill Team Structures

| Skill | Team Name | Teammates |
|-------|-----------|-----------|
| /qa-autonomous-e2e | qa-e2e-<key> | analyst + browser + developer + tester |
| /qa-discover-changes | qa-discovery-<scan-id> | analyst |
| /qa-triage-ticket | (no team) | Lead only |
| /qa-explore-framework | (no team) | Lead only |
| /qa-gather-locators | qa-browser-<key> | browser |
| /qa-implement-test | qa-impl-<key> | developer + tester |
| /qa-create-mr | (no team) | Lead only |
| /qa-maintain-tests | (no team) | Lead only |
| /qa-fix-failures | qa-fix-\<jobname\> | explorer + debug |

## Global Rules

- Only work with Jira project OXDEV
- Target E2E repo: `$E2E_FRAMEWORK_PATH` (set in `.env`, no default — must be configured per machine)
- MR target branch: developmentV2
- Branch naming: test/OXDEV-<num>-<short-slug>
- Max 3 stalled debug cycles per test -- cycles with progress (more tests passing) don't count toward the limit
- All agents log operations to memory/tickets/<KEY>/audit.md
- Code-writing agents MUST commit after every file change
- **Browser interaction uses a 3-tier tool hierarchy:**
  1. **`claude-in-chrome` MCP tools** (lead agent only) — when Chrome extension is connected (`claude --chrome` or `/chrome`). Shares browser login state, supports natural-language element search via `find`. Not available to subagents.
  2. **Chrome CDP** (`node .claude/skills/chrome-cdp/scripts/cdp.mjs`) — subagent primary tool. Persistent sessions across agents (playwright-agent opens, debug-agent reuses).
  3. **`playwright-cli`** — subagent fallback when CDP unavailable. Launches its own browser, uses element refs from `snapshot`.
  - Detection order: lead checks `claude-in-chrome` availability first; subagents check CDP then playwright-cli.

## E2E Framework Conventions

All tests in the E2E framework follow these patterns:
- CommonJS require() -- no ES module imports
- Serial mode: test.describe.configure({ mode: "serial", retries: 0 })
- Hook pattern: setBeforeAll, setBeforeEach, setAfterEach, setAfterAll from utils/setHooks
- Numbered tests: #1, #2, #3...
- First tests always: #1 Navigate, #2 Login (verifyLoginPage + closeWhatsNew)
- Double quotes, 4-space indent, semicolons (Prettier)
- Selectors in selectors/*.json (XPath with data-testid, pipe-separated fallbacks)
- Actions in actions/*.js (reuse existing before creating new)
- Timeouts from params/global.json
- **Assertion messages REQUIRED**: Every `expect()` and `expect.soft()` MUST include a descriptive error message as the second argument: `expect(el, "description of what failed").toBeVisible()`

### Standard Test Template

```javascript
const { test, expect } = require("@playwright/test");
const { setBeforeAll, setBeforeEach, setAfterEach, setAfterAll } = require("../../../utils/setHooks");
const logger = require("../../../logging");
const { navigation } = require("../../../actions/general");
const { verifyLoginPage, closeWhatsNew } = require("../../../actions/login");

let testName = "myFeature";
let orgName = process.env.SANITY_ORG_NAME;
let userName = process.env.SANITY_USER;
let userPassword = process.env.USER_PASSWORD;
let url = process.env.LOGIN_URL;
let acceptedUrl = process.env.POST_LOGIN_URL;
let environment = process.env.ENVIRONMENT;
let testTimeOut = parseInt(process.env.TEST_TIMEOUT);
let page, context;

test.describe.configure({ mode: "serial", retries: 0 });
test.setTimeout(testTimeOut);

test.beforeAll(async ({}) => {
    ({ page, context } = await setBeforeAll(testName, userName, orgName, url, environment, false));
});
test.beforeEach(async ({}, testInfo) => { await setBeforeEach(testInfo); });
test.afterEach(async ({}, testInfo) => { await setAfterEach(testInfo, orgName); });
test.afterAll(async ({}, testInfo) => { await setAfterAll(testInfo, environment, testName, orgName); });

test("#1 Navigate to homepage", async () => {
    await navigation(page, url);
});

test("#2 Login", async () => {
    await verifyLoginPage(page, userName, userPassword, acceptedUrl);
    await closeWhatsNew(page);
});

test("#3 Verify feature", async () => {
    // Every expect MUST include an error message
    expect(element, `"Feature" element should be visible`).toBeVisible();
    expect.soft(count, `Expected count to be ${expected}`).toBe(expected);
});
```

### Selector Pattern

```json
{
    "menuItem": "//*[@data-testid='menu-item-Name'] | //a[contains(@href,'/path')]//button",
    "filterDropdown": "//*[@data-testid='filter-dropdown'] | //div[contains(@class,'filter')]//select"
}
```

### MongoDB Baseline Pattern

When tests need baseline comparison (before/after scan), follow the pattern in tests/UI/issuesV2/issuesV2FiltersScan.test.js:
- Import { findDoc, replaceDoc } from utils/mongoDBClient
- Environment-conditional collName and ObjectId filter
- update/updateCritical/updateCriticalData flags from process.env
- Gated test blocks: if (update) { updateBaseline } else { runComparison }

### Code-Writer Output Format

The `code-writer-output.json` file's `diff` field MUST contain raw `git diff` unified format output -- NOT human-readable summaries. The dashboard parses unified diff format (`@@`, `+`, `-` lines) to render a colored diff viewer. The `report-to-dashboard.sh` script validates diffs and falls back to `git diff` if the agent wrote summaries instead.

The `feature_doc` field MUST contain a plain-English description (2-4 sentences) of what the test does, written for QA reviewers / product managers. This is displayed in the dashboard's "Doc" column.

### Video Recording & Upload

After a passing test run, the test-runner agent uploads the Playwright video to S3 and stores the presigned URL:

```bash
VIDEO_URL=$(node $PROJECT_ROOT/scripts/upload-test-video.js "<testName>" "stg" 2>/dev/null)
```

- S3 bucket: `ox-e2e-testing` (eu-west-1)
- S3 key pattern: `JenkinsTests/{env}/{testName}/{timestamp}/video.webm`
- Presigned URL expires in 7 days
- Requires `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY` (loaded from framework env files)
- The URL is stored in `test-results.json` as `video_url` and forwarded to the dashboard

### Protected Files -- NEVER MODIFY

- utils/setHooks.js
- utils/setHooksAPI.js
- playwright.config.js
- params/global.json
- utils/generateAccessToken.js
- config/environments.json

## Memory Structure

### Shared (git-tracked)

- memory/framework-catalog.md -- E2E framework structure
- memory/selector-patterns.md -- Learned selector strategies
- memory/test-patterns.md -- Reusable test patterns
- memory/agents/<type>.md -- Per-agent learnings
- memory/discovery/last-scan.json -- Per-service scan timestamps

### Per-Ticket (gitignored)

- memory/tickets/<OXDEV-NNN>/ -- All stage artifacts
  - triage.json, checkpoint.json, audit.md
  - exploration.md, playwright-data.json
  - implementation.md, test-results.json
  - debug-history.md, pr-result.md

### Per-Scan (gitignored)

- memory/discovery/scans/<SCAN-ID>/ -- Discovery pipeline artifacts
  - scanner-output.json, analyzer-output.json
  - tickets-created.json, audit.md

## Pipeline Flows

### Implementation Pipeline
triage -> explorer + playwright (parallel) -> code-writer -> validator -> test-runner + debug (parallel) -> cross-env-check -> pr -> retrospective -> finalize -> review-pr

### Discovery Pipeline
scanner-team (parallel per service) -> merge -> jira-enrich (lead fetches ticket details for OXDEV refs) -> analyzer (pre-fetched diffs + Jira context) -> ticket-creator -> (optional) trigger implementation pipeline per ticket

### Fix Pipeline
fetch-from-dashboard -> identify-test-file -> pre-inspect (lead quick-fix) -> explore -> debug (reuses debug-agent) -> verify -> MR

Each stage writes checkpoint.json for resume capability.
Each stage reports to dashboard via scripts/report-to-dashboard.sh.

## Dashboard Integration

Report to RFE dashboard at http://localhost:3459 (or DASHBOARD_URL env var).
Script: scripts/report-to-dashboard.sh <ticket-key> <stage> [--status STATUS]
Endpoint: POST /api/e2e-agent/report
Stage mapping: scanner, analyzer, ticket-creator, triage, explorer, playwright, code-writer, test-runner, pr, review-pr
Never blocks pipeline -- failures logged and skipped.

### Fix Pipeline (auto-fix failing tests)

```bash
# Fetch automation_issue failures from Dev, show interactive list
/qa-fix-failures

# Fix specific job's failure
/qa-fix-failures --job settingsExclude

# Target Stg folder, dev environment
/qa-fix-failures --folder Stg --env dev

# Fix a different failure category
/qa-fix-failures --category possible_real_issue
```

## Pipeline Scripts

| Script | Purpose |
|--------|---------|
| `scripts/report-to-dashboard.sh` | Report stage completion to RFE dashboard |
| `scripts/upload-test-video.js` | Upload Playwright test video to S3, return presigned URL. Used by test-runner after passing tests. |
| `scripts/watch-check.sh` | Re-check Jira ticket between phases (used by `--watch` flag). Detects description changes and ticket closure. |
| `scripts/fetch-dashboard-failures.sh` | Fetch categorized test failures from timeline-dashboard API. Used by `/qa-fix-failures`. |
| `scripts/worker.js` | Persistent worker daemon. Connects to dashboard WS, receives `trigger_pipeline` commands, spawns Claude Code. |

## Worker Mode (Dashboard-Triggered Pipelines)

Instead of manually invoking skills in a terminal, users can trigger pipelines from the RFE dashboard. A persistent worker daemon runs on the developer's machine and listens for triggers.

### Starting the Worker

```bash
# Start worker daemon
./scripts/start.sh --worker

# With custom concurrency
./scripts/start.sh --worker --capacity 2
```

### How It Works

1. Worker connects to dashboard WS as `type: "worker_hello"`
2. Dashboard tracks connected workers and shows status in the header
3. User clicks "Start Pipeline" in the dashboard → server creates DB record → forwards `trigger_pipeline` to an available worker
4. Worker validates inputs, builds the skill command, spawns `./scripts/start.sh -p "<command>"`
5. Worker reports lifecycle events (`started`, `completed`, `failed`) back via WS
6. Worker supports `kill_pipeline` to abort running jobs

### Pipeline Types Supported

| Dashboard Action | Worker Command |
|---|---|
| Jira ticket → Implementation | `/qa-autonomous-e2e OXDEV-123 [--auto] [--watch] [--env stg]` |
| Discovery scan | `/qa-discover-changes [services] [--since DATE] [--until DATE]` |
| Discovery from ticket | `/qa-discover-changes --ticket OXDEV-456 --type rfe` |
| Fix failing tests | `/qa-fix-failures [--job NAME] [--folder F] [--category C]` |

### Environment

The worker inherits all env vars from `.env` (loaded by `start.sh`). No additional config needed — same setup as manual runs. `WORKER_CAPACITY` env var can override the default capacity of 1.

## Jira Integration

Use the jira-api skill for all Jira operations:
- Fetch ticket details: GET /rest/api/2/issue/<KEY>
- Update ticket status and labels
- Add comments with progress updates
- Only project OXDEV is allowed

### acli Command Syntax

```bash
# Add labels
acli jira workitem edit --key "OXDEV-123" --labels "ai-in-progress" --yes

# Remove labels
acli jira workitem edit --key "OXDEV-123" --remove-labels "ai-ready" --yes

# View ticket
acli jira workitem view OXDEV-123 --fields "key,summary,description,labels,status"

# Add comment
acli jira workitem comment create --key "OXDEV-123" --body "comment text"
```

NEVER use `acli jira issue label add`, `acli jira workitem update --labels`, or `acli jira workitem comment add` -- these are invalid commands. The correct comment command is `comment create`.

## GitLab Integration

Use the glab-api skill for merge request operations:
- Create MR targeting developmentV2
- Add description with test summary and Jira link
- Assign reviewers from CODEOWNERS if available

## Running the Pipeline

### Implementation Pipeline (from Jira ticket)

```bash
# Full autonomous pipeline with ticket watching
/qa-autonomous-e2e OXDEV-1234 --auto --watch

# Full autonomous pipeline targeting dev environment
/qa-autonomous-e2e OXDEV-1234 --auto --env dev

# Full autonomous pipeline (basic)
/qa-autonomous-e2e OXDEV-1234

# Individual stages (for debugging or manual intervention)
/qa-triage-ticket OXDEV-1234
/qa-explore-framework OXDEV-1234
/qa-gather-locators OXDEV-1234
/qa-implement-test OXDEV-1234
/qa-create-mr OXDEV-1234
```

### Discovery Pipeline (auto-detect changes)

```bash
# Scan all services for changes since last scan
/qa-discover-changes

# Scan specific service
/qa-discover-changes frontend

# Scan with date range
/qa-discover-changes --since 2026-03-01 --until 2026-03-13

# Scan multiple services, create tickets only (don't trigger pipeline)
/qa-discover-changes frontend connectors --since 2026-03-01 --no-auto

# Read a specific Jira ticket, analyze it, and create a QA E2E test ticket
/qa-discover-changes --ticket OXDEV-12345 --type rfe

# Same but don't trigger the E2E pipeline after ticket creation
/qa-discover-changes --ticket OXDEV-12345 --type bug --no-auto

# Create test from a free-text prompt (no Jira ticket or GitLab scan needed)
/qa-discover-changes --prompt "Test the severity filter dropdown on Issues page"
/qa-discover-changes --prompt "Verify RBAC role switching for admin and viewer" --no-auto
```

## Pipeline Flags

### Implementation Pipeline
| Flag | Description |
|------|-------------|
| `--auto` | Skip plan approval for code-writer phase. Enables fully unattended runs. |
| `--watch` | Re-check Jira ticket between phases. If description changed, re-triages and restarts affected stages. If ticket closed, aborts gracefully. |
| `--env dev\|stg` | Target environment for browser and test execution (default: stg) |

Flags can be combined: `/qa-autonomous-e2e OXDEV-1234 --auto --watch`

### Discovery Pipeline
| Flag | Description |
|------|-------------|
| `--since YYYY-MM-DD` | Override scan start date (default: last scan timestamp or 7 days ago). |
| `--until YYYY-MM-DD` | Override scan end date (default: now). |
| `--no-auto` | Only create Jira tickets — do not trigger E2E test pipeline for created tickets. |
| `--ticket OXDEV-NNN` | Skip GitLab scanning. Read the provided Jira ticket, analyze it, and create a QA E2E test ticket with steps. Requires `--type`. Incompatible with service names, `--since`, `--until`. |
| `--type bug\|rfe\|task\|sprint` | Discovery type (required with `--ticket`). Sets scan ID to `<TYPE>-<TICKET-KEY>-DIS` (e.g., `RFE-OXDEV-123-DIS`). |
| `--prompt "text"` | Skip GitLab and Jira. Use free-text description as source for the Analyzer. Scan ID: `PROMPT-DIS-<YYYY-MM-DD-HHmm>`. Incompatible with `--ticket`, service names, `--since`, `--until`. |
| `--scan-id ID` | Override the auto-generated scan ID. Used by the worker daemon to pass dashboard-originated pipeline keys. |

### Fix Pipeline
| Flag | Description |
|------|-------------|
| `--folder Staging\|Dev\|Prod` | Jenkins folder to query (default: Staging). Aliases: Stg→Staging. |
| `--view <view>` | Jenkins view (default: AA_Release). |
| `--job <name>` | Filter to a specific job by partial name match. Skips the selection prompt. |
| `--env stg\|dev` | Target environment for test execution (default: stg). |
| `--category <cat>` | Failure category to fetch (default: automation_issue). |

## Error Handling

- Each stage validates its prerequisites before starting
- Failed stages write error details to checkpoint.json
- Debug runs in parallel with test-runner, max 3 stalled cycles (progress resets the counter)
- After 3 stalled cycles (no progress): add ai-failed label to Jira ticket, stop pipeline
- All errors logged to memory/tickets/<KEY>/audit.md

## Environment Variables

Required in .env:
- JIRA_BASE_URL -- Jira instance URL
- JIRA_TOKEN -- Jira API token
- JIRA_USER -- Jira username/email
- GITLAB_TOKEN -- GitLab API token
- DASHBOARD_URL -- RFE dashboard URL (default: http://localhost:3459)
- E2E_FRAMEWORK_PATH -- Absolute path to E2E framework repo (REQUIRED, no default)
- STAGING_URL -- Staging app URL (default: https://stg.app.ox.security)
- STAGING_USER -- Staging automation user email
- STAGING_PASSWORD -- Staging automation user password
- CDP_PORT_FILE -- (optional) Path to file containing Chrome CDP port, for custom Chrome location

### Staging Credentials for playwright-cli

The framework env files are NOT available as shell env vars. When using `playwright-cli` for browser exploration, use the env vars set by `setup.sh`:
- URL: `$STAGING_URL` (default: `https://stg.app.ox.security`)
- User: `$STAGING_USER` (default: `automation+performance@ox.security`)
- Password: `$STAGING_PASSWORD`

These env vars are injected via `.claude/settings.local.json` and `.env`. Never hardcode credentials in agent definitions or skill files.

### Framework Env Files -- NEVER source in shell

The E2E framework env files (`env/.env.stg`, `env/.env.dev`, etc.) use **colon syntax** (`KEY: "value"`), NOT shell-compatible `KEY=value` format. They are parsed by `dotenv` via `playwright.config.js`:

```javascript
require("dotenv").config({ path: "env/" + process.env.envFile });
```

- **NEVER** run `source env/.env.stg` or `. env/.env.stg` -- this will fail with "command not found" errors
- **NEVER** try to parse env files with bash `sed`/`awk` to extract values
- To run tests: use `envFile=.env.stg npx playwright test ...` -- this sets the `envFile` shell variable that playwright.config.js reads
- To read env values programmatically: read the file and parse the `KEY: "value"` format, or inspect `process.env` after Playwright loads

## Dashboard Reporting

Every pipeline stage MUST report to the dashboard after completion. Use:

```bash
./scripts/report-to-dashboard.sh <TICKET-KEY> <stage> --status completed
```

This is a bash command the lead MUST execute (not documentation). The script never blocks the pipeline -- errors are logged and skipped. If the lead skips dashboard reports, the dashboard shows stale/incomplete data.

## Per-Agent Permission Policies

Each agent has a JSON policy file in `.claude/policies/` that declares its permissions:

- `_common.json` -- shared rules (protected files, protected branches, Jira scope, banned patterns, exec deny list, loop detection config)
- `<agent-name>.json` -- per-agent overrides (filesystem read/write, network, jira/git access, required outputs, credentials, exec allowlists)

Policy files are loaded by `scripts/load-policy.py`, which deep-merges `_common.json` with the agent-specific policy. Validation hooks read from policies with hardcoded fallbacks if the policy system fails.

```bash
# View merged policy for an agent
python3 scripts/load-policy.py playwright-agent

# Query a specific field
python3 scripts/load-policy.py _common --field filesystem.never_modify
```

Agent `.md` files include a `policy:` frontmatter field cross-referencing their policy file.

### Exec Allowlists

Each agent policy declares `exec.allow_patterns` (glob patterns for permitted commands) and inherits `exec.deny_patterns` from `_common.json`. Deny patterns take precedence. The `validate-exec-allowlist.sh` hook enforces this per-agent. The lead agent is unrestricted; only teammates are constrained.

### Tool-Loop Detection

`validate-loop-detection.sh` tracks recent Bash commands in a sliding window and blocks when agents get stuck:
- **Repeat detection**: same command run >6 times consecutively
- **Ping-pong detection**: alternating between 2 commands >8 times

Thresholds are configurable via `_common.json` `exec.loop_detection`. State resets after a block to allow recovery.

## Output Schema Validation

`scripts/validate-output-schema.py` validates pipeline output files against per-stage JSON schemas. It runs automatically via `validate-task-completed.sh` and `validate-teammate-idle.sh` hooks.

```bash
# Validate a stage's output
python3 scripts/validate-output-schema.py OXDEV-123 triage

# Validate checkpoint only
python3 scripts/validate-output-schema.py OXDEV-123 checkpoint
```

Returns JSON: `{"valid": true/false, "errors": [...], "warnings": [...]}`. Graceful degradation: if Python fails, hooks allow through.

## Documentation

When making changes to this project (agents, skills, rules, scripts, pipeline behavior, flags, conventions), **always update `README.md`** to reflect those changes. The README is the primary external-facing documentation and must stay in sync with the actual behavior of the system.

---

# General-Purpose (GP) Test Agent

The GP system is a **platform-agnostic extension** of this agent. It supports any ticket platform, any test framework, and any VCS provider. It runs alongside the existing OX Security pipeline without conflicting with it.

## GP Architecture

### 10-Stage Pipeline

```
intake → plan → scaffold → [browse] → codegen → run → report → [debug×3] → pr → learn
```

| Stage | Agent | Model | Purpose |
|-------|-------|-------|---------|
| intake | gp-intake-agent | Haiku | Read ticket from any platform, normalize to TicketPayload |
| plan | gp-planner-agent | Sonnet | Analyze requirements, select framework/language/VCS, decompose into test steps |
| scaffold | gp-scaffolder-agent | Sonnet | Create project structure, install deps, create git branch |
| browse | gp-browser-agent | Sonnet | Explore UI via CDP/playwright-cli, capture selectors/screenshots |
| codegen | gp-codegen-agent | Opus | Generate POM classes, selectors, helpers, test file |
| run | gp-runner-agent | Sonnet | Execute tests, parse results to canonical JSON |
| report | gp-reporter-agent | Haiku | Generate Allure/HTML reports |
| debug | gp-debugger-agent | Opus | Fix failures, max 3 stalled cycles |
| pr | gp-pr-agent | Haiku | Push branch, create PR/MR on VCS provider |
| learn | gp-learner-agent | Haiku | Extract learnings to shared memory |

### Skill Commands

| Skill | Usage |
|-------|-------|
| `/gp-test-agent` | Full autonomous pipeline (any platform, any framework) |
| `/gp-init-project` | Scaffold a fresh test project for any framework |
| `/gp-scan-tickets` | Discover automation candidates across platforms |
| `/gp-fix-tests` | Auto-fix failing tests in any framework |

### Supported Platforms

| Platform | Config | Key Format |
|----------|--------|------------|
| Jira (any project) | `config/platforms/jira-any.json` | `PROJ-123` |
| Azure DevOps | `config/platforms/azure-devops.json` | `456` or URL |
| GitHub Issues | `config/platforms/github-issues.json` | `#42` or URL |
| Linear | `config/platforms/linear.json` | `PROJ-123` |
| ServiceNow | `config/platforms/servicenow.json` | `INC001234` |

### Supported Frameworks

| Framework | Config | Languages |
|-----------|--------|-----------|
| Playwright JS | `config/frameworks/playwright-js.json` | JavaScript |
| Playwright TypeScript | `config/frameworks/playwright-typescript.json` | TypeScript |
| Playwright Python | `config/frameworks/playwright-python.json` | Python |
| Selenium Python | `config/frameworks/selenium-python.json` | Python |
| Selenium Java | `config/frameworks/selenium-java.json` | Java |
| Cypress JS | `config/frameworks/cypress-js.json` | JavaScript |
| Appium Python | `config/frameworks/appium-python.json` | Python (mobile) |
| Appium Java | `config/frameworks/appium-java.json` | Java (mobile) |
| Robot Framework | `config/frameworks/robot-framework.json` | Robot/Python |

### Supported VCS Providers

| Provider | Config | CLI |
|----------|--------|-----|
| GitHub | `config/vcs/github.json` | `gh` |
| GitLab | `config/vcs/gitlab.json` | `glab` |
| Azure Repos | `config/vcs/azure-repos.json` | `az` |

## Running the GP Pipeline

```bash
# Full pipeline (auto-detects platform, framework, VCS)
/gp-test-agent PROJ-123

# With explicit framework and VCS
/gp-test-agent PROJ-123 --framework playwright-js --vcs github

# From GitHub Issue URL
/gp-test-agent https://github.com/org/repo/issues/42 --framework cypress-js

# From Azure DevOps URL
/gp-test-agent https://dev.azure.com/org/project/_workitems/edit/456 --auto

# Skip browser exploration (use ticket description only)
/gp-test-agent PROJ-123 --no-browse

# Full unattended run (no prompts)
/gp-test-agent PROJ-123 --auto --framework playwright-js

# Initialize a new test project
/gp-init-project --framework playwright-js --ci github --reporter allure

# Scan for automation candidates
/gp-scan-tickets --platform jira --project PROJ --label qa-ready

# Fix failing tests
/gp-fix-tests test-results/results.json --framework playwright-js --create-pr
```

## GP Pipeline Flags

### /gp-test-agent
| Flag | Description |
|------|-------------|
| `--platform` | Override platform auto-detection |
| `--framework` | Override framework selection |
| `--vcs` | Override VCS provider auto-detection |
| `--language` | Override language (uses framework default) |
| `--project-path` | Absolute path to test project |
| `--env` | Target environment (staging/dev/prod) |
| `--auto` | Skip all interactive prompts |
| `--no-browse` | Skip UI browser exploration |
| `--no-pr` | Generate code but no PR |
| `--resume` | Resume from checkpoint after failure |

## GP Config Files (Config-Driven — Adding New Platforms)

Adding a new ticket platform requires ONLY creating a new JSON file in `config/platforms/`:

```json
{
  "platform_id": "my-platform",
  "display_name": "My Platform",
  "ticket_key_pattern": "^[A-Z]+-[0-9]+$",
  "auth": { "type": "api_token", "env_vars": { "token": "MY_API_TOKEN" } },
  "read_command": { "type": "curl", "template": "curl -sf -H 'Auth: ${MY_API_TOKEN}' 'https://api.myplatform.com/tickets/{ticket_id}'" },
  "field_map": { "title": "data.title", "description": "data.body", "acceptance_criteria": "data.ac" }
}
```

No agent code changes required. Same approach for frameworks (`config/frameworks/`) and VCS providers (`config/vcs/`).

## GP Memory Structure

### Shared (git-tracked)
- `memory/gp/platform-patterns.md` — accumulated platform API learnings
- `memory/gp/framework-patterns.md` — framework setup and selector gotchas
- `memory/gp/failure-catalog.md` — indexed failure→fix patterns (self-learning)
- `memory/gp/vcs-patterns.md` — VCS CLI and PR creation learnings
- `memory/gp/run-history.md` — summary table of all GP runs

### Per-Run (gitignored)
- `memory/gp-runs/<RUN_ID>/intake.json` — normalized ticket
- `memory/gp-runs/<RUN_ID>/plan.json` — test plan + selections
- `memory/gp-runs/<RUN_ID>/scaffold.json` — project setup results
- `memory/gp-runs/<RUN_ID>/browser-data.json` — selectors, nav flow
- `memory/gp-runs/<RUN_ID>/codegen.json` — generated files, diff
- `memory/gp-runs/<RUN_ID>/run-results.json` — canonical test results
- `memory/gp-runs/<RUN_ID>/report.json` — report paths
- `memory/gp-runs/<RUN_ID>/debug-history.md` — debug cycle log
- `memory/gp-runs/<RUN_ID>/pr-result.json` — PR/MR URL
- `memory/gp-runs/<RUN_ID>/checkpoint.json` — pipeline stage progress
- `memory/gp-runs/<RUN_ID>/audit.md` — timestamped operations log

## GP Scripts

| Script | Purpose |
|--------|---------|
| `scripts/gp-detect-platform.sh` | Auto-detect ticket platform from URL or key format |
| `scripts/gp-detect-framework.sh` | Auto-detect test framework from project files |
| `scripts/gp-run-tests.sh` | Framework-agnostic test execution dispatcher |
| `scripts/gp-parse-results.sh` | Parse test results (JUnit XML/Playwright JSON) to canonical JSON |
| `scripts/gp-install-framework.sh` | Install framework dependencies (npm/pip/mvn) |
| `scripts/gp-setup-allure.sh` | Configure Allure reporter for any framework |
| `scripts/gp-create-pr.sh` | VCS-agnostic PR/MR creation dispatcher |

## GP Environment Variables

Add these to `.env` for the platforms and VCS providers you use:

```bash
# General Purpose Agent
GP_TEST_PROJECT_PATH=/abs/path/to/test-projects
GP_PR_TARGET_BRANCH=main

# Jira (generic — any project)
JIRA_BASE_URL=https://yourorg.atlassian.net
JIRA_USER=automation@yourorg.com
JIRA_TOKEN=your-api-token

# GitHub (Issues or GitHub PRs)
GH_TOKEN=your-gh-token
GH_REPO=org/repo-name

# Azure DevOps
ADO_ORG=https://dev.azure.com/yourorg
ADO_PROJECT=YourProject
ADO_PAT=your-pat

# Linear
LINEAR_API_KEY=your-linear-key
LINEAR_TEAM_ID=your-team-id

# ServiceNow
SNOW_INSTANCE=yourinstance
SNOW_USER=automation_user
SNOW_PASSWORD=your-password
```

## GP Policy Rules

The `gp-common.json` base policy enforces:
- **Never modify** config driver files (`config/platforms/*.json`, `config/frameworks/*.json`, `config/vcs/*.json`)
- **Never push** to protected branches (`main`, `master`, `develop`, `release/*`)
- **Always use env vars** for credentials — never hardcode in generated test code
- **Skeleton-first** output — write empty output file before doing complex work
- **Commit in order**: selectors → pages → helpers → tests

## Coexistence with OX Security Pipeline

- All GP files use `memory/gp/` and `memory/gp-runs/` namespaces — no collision with existing `memory/tickets/`
- GP agents call Jira via `curl` directly, not `acli` — OX-specific Jira safety hooks don't intercept
- GP skills use `/gp-*` prefix — no collision with existing `/qa-*` skills
- Config driver files (`config/platforms/`, `config/frameworks/`, `config/vcs/`) are new directories
- `settings.json` permission additions are additive only — no existing permissions modified
