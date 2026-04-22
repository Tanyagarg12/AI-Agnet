
# Autonomous QA E2E Test Generation Platform

Production-grade, multi-agent QA system that autonomously generates, runs, and debugs E2E tests. Works with **any ticket system** (Jira, GitHub Issues, Azure DevOps, Linear, ServiceNow), **any Git provider** (GitHub, GitLab, Bitbucket), and **any testing framework** (Playwright, Cypress, Selenium, Puppeteer, TestCafe, Appium, Robot Framework). Powered by Claude Code Agent Teams.

## Features

- **Universal platform support** — Plug-and-play ticket, VCS, and framework integrations via JSON config files
- **Interactive CLI Wizard** — Guided setup with framework auto-detection and credential validation
- **Dashboard UI** — Real-time pipeline tracking, live logs, stage visualization, code diffs, test videos
- **Adaptive browser strategy** — 3-tier browser tool hierarchy that adapts to the selected testing framework
- **Self-healing debug loop** — Up to 3 stalled debug cycles with progress-aware counting
- **Worker daemon** — Persistent background service that receives pipeline triggers from the dashboard
- **Shared learning memory** — Agents accumulate selector patterns, failure fixes, and framework best practices across runs

---

## Quick Start

### Option 1: Interactive CLI Wizard (Recommended)

```bash
git clone <your-repo-url> && cd AI-Agnet

# Full interactive setup — detects frameworks, configures credentials, scaffolds project
./scripts/cli-wizard.sh --setup
```

The wizard walks you through:
1. **Prerequisite check** — Node.js, Git, Python3, curl
2. **Project folder selection** — Point to existing test project or create new
3. **Framework detection** — Scans `package.json`, `requirements.txt`, `pom.xml` for installed frameworks, shows results, lets you choose or install new
4. **Ticket system config** — Jira, GitHub Issues, Azure DevOps, Linear, ServiceNow (with live credential validation)
5. **Git provider config** — GitHub, GitLab, Azure Repos (with token validation)
6. **Environment config** — App URL, test credentials, PR target branch

### Option 2: Quick Setup (Non-Interactive)

```bash
# Run the basic setup script
./scripts/setup.sh
```

### After Setup

```bash
# Start the dashboard UI
./scripts/cli-wizard.sh --dashboard

# Or launch Claude Code and run a pipeline
claude
/gp-test-agent PROJ-123 --auto
```

---

## Architecture

### System Overview

```
                    ┌──────────────────┐
                    │   Dashboard UI   │ ◄── Browser (real-time via WebSocket)
                    │  localhost:3459  │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  Worker Daemon   │ ◄── Receives trigger_pipeline commands
                    │   (worker.js)    │
                    └────────┬─────────┘
                             │
              ┌──────────────▼──────────────┐
              │      Pipeline Orchestrator   │
              │    (Claude Code + Skills)    │
              └──────────────┬──────────────┘
                             │
    ┌────────┬────────┬──────┴──────┬────────┬────────┐
    ▼        ▼        ▼             ▼        ▼        ▼
 Triage  Explorer  Browser     Code-Gen  Runner   Debug
 Agent   Agent     Agent       Agent     Agent    Agent
```

### Agent Pipeline (10 Stages)

```
intake → plan → scaffold → [browse] → codegen → run → report → [debug×3] → pr → learn
```

| # | Stage | Agent | Model | Purpose |
|---|-------|-------|-------|---------|
| 1 | Intake | gp-intake-agent | Haiku | Read ticket from any platform, normalize to TicketPayload |
| 2 | Plan | gp-planner-agent | Sonnet | Analyze requirements, select framework, decompose into test steps |
| 3 | Scaffold | gp-scaffolder-agent | Sonnet | Create project structure, install deps, create git branch |
| 4 | Browse | gp-browser-agent | Sonnet | Explore UI, capture selectors and screenshots (optional) |
| 5 | Codegen | gp-codegen-agent | Opus | Generate POM classes, selectors, helpers, test file |
| 6 | Run | gp-runner-agent | Sonnet | Execute tests, parse results to canonical JSON |
| 7 | Report | gp-reporter-agent | Haiku | Generate Allure/HTML reports |
| 8 | Debug | gp-debugger-agent | Opus | Fix failures, max 3 stalled cycles |
| 9 | PR | gp-pr-agent | Haiku | Push branch, create PR/MR |
| 10 | Learn | gp-learner-agent | Haiku | Extract learnings to shared memory |

Each agent:
- Is **stateless** between runs (shared context via memory files)
- Outputs **structured JSON** with defined schemas
- Respects **strict safety rules** (no credential leaks, no protected branch commits)
- Writes **skeleton output first** (incremental writes, never relies on final turn)

### OX Security Pipeline (Implementation)

For the OX Security E2E framework specifically:

| Agent | Model | Purpose |
|-------|-------|---------|
| triage | Haiku | Classify OXDEV ticket |
| explorer | Sonnet | Find similar tests in framework |
| playwright | Sonnet | Browser locator gathering via CDP |
| code-writer | Opus | Write test + actions + selectors |
| validator | Haiku | Convention compliance check |
| test-runner | Sonnet | Execute and parse results |
| debug | Opus | Fix failures (max 3 stalled cycles) |
| pr | Haiku | Create MR to developmentV2 |
| retrospective | Haiku | Record learnings |

### Discovery Pipeline

| Agent | Model | Purpose |
|-------|-------|---------|
| scanner | Haiku | Scan GitLab for merged MRs |
| analyzer | Sonnet | Classify changes, group into scenarios |
| ticket-creator | Opus | Create OXDEV Jira tickets |

---

## Framework Detection & Selection

The platform analyzes your project folder and guides you through framework selection.

### Detection Flow

```
┌─────────────────────────┐
│  Analyze Project Folder │
└───────────┬─────────────┘
            │
     ┌──────▼──────┐
     │ package.json │──── Yes ──► Parse dependencies for testing tools
     │   exists?    │             (Playwright, Cypress, Selenium, etc.)
     └──────┬──────┘
            │ No
     ┌──────▼──────────┐
     │ requirements.txt │──► Check Python frameworks
     │ pom.xml          │──► Check Java frameworks
     │ *.robot files    │──► Check Robot Framework
     └──────┬──────────┘
            │
     ┌──────▼──────────┐
     │ Show Detection  │──► List all found frameworks with versions
     │ Results         │    or "No framework detected"
     └──────┬──────────┘
            │
     ┌──────▼──────────┐
     │ User Decision   │──► 1) Use detected framework
     │                 │    2) Choose different framework
     │                 │    3) Initialize new setup
     └──────┬──────────┘
            │
     ┌──────▼──────────┐
     │ Full Selection  │──► 11 frameworks with descriptions,
     │ Menu            │    pros, and setup complexity
     └─────────────────┘
```

### Supported Frameworks

| Framework | Language | Best For | Setup |
|-----------|----------|----------|-------|
| **Playwright (JS)** | JavaScript | Modern web apps, cross-browser, API testing | Easy |
| **Playwright (TS)** | TypeScript | Type-safe test suites, large teams | Easy |
| **Playwright (Python)** | Python | Python teams, pytest integration | Easy |
| **Cypress** | JavaScript | Component testing, SPAs, visual testing | Easy |
| **Selenium (Python)** | Python | Cross-browser, legacy apps, widespread adoption | Medium |
| **Selenium (Java)** | Java | Enterprise teams, CI/CD pipelines | Medium |
| **Puppeteer** | JavaScript | Chrome-specific, scraping, PDFs | Easy |
| **TestCafe** | JavaScript | No WebDriver needed, proxy-based | Easy |
| **Appium (Python)** | Python | Android/iOS native/hybrid apps | Complex |
| **Appium (Java)** | Java | Enterprise mobile testing | Complex |
| **Robot Framework** | Robot/Python | Keyword-driven, non-developers, BDD | Medium |

### Adding a New Framework

Create a JSON file in `config/frameworks/`:

```json
{
    "framework_id": "my-framework",
    "display_name": "My Framework",
    "language": "javascript",
    "install_commands": ["npm install my-framework"],
    "run_command": "npx my-framework run {test_file}",
    "conventions": { "selector_strategy": "css", "use_page_object_model": true }
}
```

No agent code changes required.

---

## Supported Platforms

### Ticket Systems

| Platform | Config | Key Format | Auth |
|----------|--------|------------|------|
| Jira (any project) | `config/platforms/jira-any.json` | `PROJ-123` | API token |
| GitHub Issues | `config/platforms/github-issues.json` | `#42` or URL | GH_TOKEN |
| Azure DevOps | `config/platforms/azure-devops.json` | `456` or URL | ADO_PAT |
| Linear | `config/platforms/linear.json` | `PROJ-123` | LINEAR_API_KEY |
| ServiceNow | `config/platforms/servicenow.json` | `INC001234` | User/Password |

### VCS Providers

| Provider | Config | CLI |
|----------|--------|-----|
| GitHub | `config/vcs/github.json` | `gh` |
| GitLab | `config/vcs/gitlab.json` | `glab` |
| Azure Repos | `config/vcs/azure-repos.json` | `az` |

### Adding a New Platform

Create a JSON file in `config/platforms/`:

```json
{
    "platform_id": "my-platform",
    "display_name": "My Platform",
    "ticket_key_pattern": "^[A-Z]+-[0-9]+$",
    "auth": { "type": "api_token", "env_vars": { "token": "MY_API_TOKEN" } },
    "read_command": { "type": "curl", "template": "curl -sf -H 'Auth: ${MY_API_TOKEN}' 'https://api.myplatform.com/tickets/{ticket_id}'" },
    "field_map": { "title": "data.title", "description": "data.body" }
}
```

---

## Browser Automation Strategy

The platform uses an adaptive 3-tier browser tool hierarchy:

| Tier | Tool | When | Advantage |
|------|------|------|-----------|
| **1** | `claude-in-chrome` | Lead agent, Chrome extension connected | Shares user's login state |
| **2** | Chrome CDP | Subagents, Chrome with remote debugging | Persistent sessions across agents |
| **3** | Framework-specific | Always available | Matches user's chosen framework |

### Tier 3 Adapts to Framework

| Selected Framework | Tier 3 Tool | Fallback |
|-------------------|-------------|----------|
| Playwright (any) | `playwright-cli` | — |
| Cypress | `cypress-runner` | `playwright-cli` |
| Selenium (any) | `selenium-webdriver` | `playwright-cli` |
| Puppeteer | `puppeteer-scripts` | `playwright-cli` |
| TestCafe | `testcafe-runner` | `playwright-cli` |
| Appium (any) | `appium-client` | `playwright-cli` |
| Robot Framework | `robotframework-browser` | `playwright-cli` |

Playwright always serves as the universal fallback.

---

## CLI Commands

### Setup & Configuration

```bash
./scripts/cli-wizard.sh --setup       # Full interactive setup
./scripts/cli-wizard.sh --run         # Launch a pipeline interactively
./scripts/cli-wizard.sh --status      # Check system status
./scripts/cli-wizard.sh --dashboard   # Start the dashboard web UI
```

### Pipeline Commands (inside Claude Code)

```bash
# GP Pipeline — any platform, any framework
/gp-test-agent PROJ-123                                    # Auto-detect everything
/gp-test-agent PROJ-123 --framework playwright-js --auto   # Explicit framework, no prompts
/gp-test-agent https://github.com/org/repo/issues/42      # From GitHub Issue URL
/gp-test-agent PROJ-123 --no-browse --no-pr                # Skip browser, skip PR

# OX Security Pipeline — OXDEV Jira tickets
/qa-autonomous-e2e OXDEV-1234                              # Full pipeline
/qa-autonomous-e2e OXDEV-1234 --auto --watch --env dev     # Autonomous + watch + dev env

# Discovery
/qa-discover-changes                                       # Scan all services
/qa-discover-changes --ticket OXDEV-456 --type rfe         # From Jira ticket
/qa-discover-changes --prompt "Test the severity filter"   # From free text

# Fix
/qa-fix-failures --job settingsExclude                     # Fix specific failing test
/gp-fix-tests test-results/results.xml                     # Fix from results file

# Utilities
/gp-init-project --framework playwright-js                 # Scaffold new test project
/gp-scan-tickets --platform jira --label qa-ready          # Find automation candidates
```

### Pipeline Flags

| Flag | Description | Pipelines |
|------|-------------|-----------|
| `--auto` | Skip all interactive prompts | All |
| `--framework <id>` | Override framework auto-detection | GP |
| `--vcs <provider>` | Override VCS auto-detection | GP |
| `--platform <id>` | Override ticket platform detection | GP |
| `--env dev\|stg` | Target environment | All |
| `--no-browse` | Skip browser exploration | GP |
| `--no-pr` | Generate code but no PR | GP |
| `--resume` | Resume from checkpoint | All |
| `--watch` | Re-check ticket between phases | OX |
| `--since/--until` | Date range for discovery | Discovery |

---

## Dashboard UI

The dashboard provides real-time pipeline management through a web interface.

### Starting the Dashboard

```bash
./scripts/cli-wizard.sh --dashboard
# Or directly:
cd dashboard && npm install && node server.js
```

Opens at `http://localhost:3459`.

### Features

| Feature | Description |
|---------|-------------|
| **Pipeline List** | All pipelines with status, stage progress dots, and time |
| **Pipeline Detail** | Stage timeline, test results, video player, code diff viewer |
| **Trigger Form** | Start new pipelines (implementation, discovery, fix) from the UI |
| **Live Logs** | Real-time log streaming per pipeline via WebSocket |
| **Worker Status** | Connected workers with capacity and running jobs |
| **Config View** | Available frameworks, platforms, system status |

### API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/pipelines` | GET | List all pipelines |
| `/api/pipelines` | POST | Trigger new pipeline |
| `/api/pipelines/:id` | GET | Get pipeline details |
| `/api/pipelines/:id` | DELETE | Cancel pipeline |
| `/api/pipelines/:id/logs` | GET | Fetch pipeline logs |
| `/api/e2e-agent/report` | POST | Stage completion report (used by agents) |
| `/api/workers` | GET | List connected workers |
| `/api/status` | GET | System status summary |
| `/api/config/frameworks` | GET | Available frameworks |
| `/api/config/platforms` | GET | Available ticket platforms |

### WebSocket Protocol

Connect to `ws://localhost:3459/ws` for real-time updates:

| Message Type | Direction | Description |
|-------------|-----------|-------------|
| `init` | Server → Client | Current state on connection |
| `pipeline_update` | Server → Client | Pipeline status change |
| `log_entry` | Server → Client | New log line |
| `stage_update` | Server → Client | Stage completion |
| `worker_connected` | Server → Client | Worker came online |
| `trigger_pipeline` | Client → Server | Start a pipeline |

### Worker Mode

```bash
# Start a persistent worker daemon
./scripts/start.sh --worker

# With custom concurrency
./scripts/start.sh --worker --capacity 2
```

Workers connect to the dashboard via WebSocket, receive `trigger_pipeline` commands, spawn Claude Code processes, and report lifecycle events.

---

## Directory Structure

```
AI-Agnet/
├── .claude/
│   ├── agents/              # 22 agent definitions (OX + GP)
│   ├── skills/              # Skill definitions for each pipeline
│   ├── policies/            # Per-agent permission policies (JSON)
│   ├── rules/               # Safety and coding rules
│   └── settings.json        # Permissions, hooks, env config
├── config/
│   ├── frameworks/          # Framework configs (playwright-js.json, etc.)
│   ├── platforms/           # Ticket platform configs (jira-any.json, etc.)
│   ├── vcs/                 # VCS provider configs (github.json, etc.)
│   ├── environments.json    # Multi-environment config
│   └── gp-defaults.json     # GP pipeline defaults
├── dashboard/
│   ├── server.js            # Express + WebSocket backend
│   ├── public/
│   │   ├── index.html       # Dashboard SPA
│   │   ├── app.js           # Frontend JavaScript
│   │   └── styles.css       # Dashboard styles
│   └── package.json         # Dashboard dependencies
├── scripts/
│   ├── cli-wizard.sh        # Interactive CLI wizard (setup/run/status/dashboard)
│   ├── setup.sh             # Basic setup script
│   ├── start.sh             # Launch Claude Code with guardrails
│   ├── worker.js            # Persistent worker daemon
│   ├── detect-framework-interactive.sh  # Enhanced framework detection
│   ├── validate-credentials.sh          # API token validation
│   ├── browser-strategy.sh              # Adaptive browser tier selection
│   ├── gp-detect-framework.sh           # Auto-detect framework (non-interactive)
│   ├── gp-detect-platform.sh            # Auto-detect ticket platform
│   ├── gp-run-tests.sh                  # Framework-agnostic test runner
│   ├── gp-parse-results.sh              # Test result parser
│   ├── gp-install-framework.sh          # Dependency installer
│   ├── gp-create-pr.sh                  # VCS-agnostic PR creation
│   ├── report-to-dashboard.sh           # Stage reporting
│   ├── validate-*.sh                    # Safety validation hooks
│   └── load-policy.py                   # Agent policy loader
├── templates/
│   ├── gp/codegen/          # Framework-specific code templates
│   ├── gp/pom/              # POM class templates (JS/Python/Java)
│   └── gp/pr/               # PR description templates
├── memory/
│   ├── gp/                  # GP shared learnings (git-tracked)
│   ├── agents/              # Per-agent learnings (git-tracked)
│   ├── tickets/             # Per-ticket artifacts (gitignored)
│   └── gp-runs/             # Per-GP-run artifacts (gitignored)
├── tests/dry-run/           # Pipeline dry-run test data
├── CLAUDE.md                # Project instructions for Claude Code
└── .env                     # Environment configuration (gitignored)
```

---

## Safety Rules

### Credential Protection
- Credentials stored only in `.env` (gitignored)
- `validate-no-credential-leak.sh` hook blocks commands printing literal credential values
- API tokens validated via lightweight API calls during setup
- Generated test code uses env vars exclusively — never hardcodes URLs, credentials, or secrets

### Git Safety
- Protected branches: `main`, `master`, `developmentV2`, `development`, `release/*`
- No force-push, no branch deletion, no direct commits to protected branches
- Branch naming: `test/<ticket-id>-<slug>` or `feat/`, `fix/`, `chore/`

### Debug Limits
- Max 3 **stalled** debug cycles (progress resets counter)
- After limit: pipeline stops, adds failure label to ticket

### Per-Agent Policies
- Each agent has a JSON policy in `.claude/policies/`
- Declares: filesystem access, network targets, Jira/Git permissions, required outputs
- Validation hooks enforce policies with hardcoded fallbacks

### Exec Safety
- Per-agent command allowlists (`exec.allow_patterns`)
- Global deny patterns block dangerous commands
- Tool-loop detection (repeat and ping-pong patterns)

---

## Environment Variables

Create `.env` via the CLI wizard or manually:

```bash
# Test Project
GP_TEST_PROJECT_PATH=/path/to/test-project
GP_FRAMEWORK=playwright-js
GP_PR_TARGET_BRANCH=main

# Test Environment
STAGING_URL=https://staging.yourapp.com
TEST_USER=automation@yourapp.com
TEST_PASSWORD=your-password

# Jira (optional)
JIRA_BASE_URL=https://yourorg.atlassian.net
JIRA_USER=user@yourorg.com
JIRA_TOKEN=your-api-token

# GitHub (optional)
GH_TOKEN=your-gh-token
GH_REPO=org/repo

# GitLab (optional)
GITLAB_TOKEN=your-gitlab-pat
GITLAB_API_URL=https://gitlab.com/api/v4

# Azure DevOps (optional)
ADO_ORG=https://dev.azure.com/yourorg
ADO_PROJECT=YourProject
ADO_PAT=your-pat

# Dashboard
DASHBOARD_PORT=3459
```

---

## Pipeline Resume

Every stage writes `checkpoint.json` with `completed_stages`, `current_stage`, and `stage_outputs`. If interrupted, re-running the same command with `--resume` skips completed stages.

---

## Output Schema

Each pipeline stage outputs structured JSON:

```json
{
    "stage": "codegen",
    "status": "completed",
    "data": {
        "test_file": "tests/login.spec.js",
        "selectors_file": "config/selectors/login.json",
        "page_objects": ["pages/LoginPage.js"]
    },
    "errors": [],
    "metrics": {
        "lines_generated": 142,
        "duration_seconds": 15
    }
}
```

---

## Contributing

1. Clone and set up: `./scripts/cli-wizard.sh --setup`
2. Create a branch: `git checkout -b feat/your-feature`
3. Make changes and test: `./scripts/cli-wizard.sh --run`
4. Submit a PR

When changing agents, skills, rules, scripts, or pipeline behavior — always update this README.
