---
name: qa-gather-locators
description: Use Playwright CLI to browse the live application, screenshot pages, and gather element locators for E2E test development. Spawns a browser teammate.
disable-model-invocation: true
argument-hint: "[ticket-key]"
---

# Gather Locators via Playwright Browser

Browse the live application using Playwright CLI to gather element locators needed for E2E test development.

## Usage

```
/qa-gather-locators OXDEV-123
/qa-gather-locators OXDEV-123 --env dev
```

## Flags

Parse `$ARGUMENTS`:
- **Ticket key** (required): The Jira ticket key (e.g., OXDEV-123)
- **`--env dev|stg`**: Target environment for browser exploration. Default: `stg`. Reads credentials from `config/environments.json`.

## Prerequisites

- `memory/tickets/$ARGUMENTS/triage.json` must exist (run `/qa-triage-ticket` first)
- `memory/tickets/$ARGUMENTS/exploration.md` should exist for best results (run `/qa-explore-framework` first)
- Playwright CLI must be installed (`npm install -g @playwright/cli@latest`)

## Team Structure

Create team `qa-browser-$ARGUMENTS` with one browser teammate.

## Process

### Step 1: Load Context

1. Read `memory/tickets/$ARGUMENTS/triage.json` for target pages and org
2. Read `memory/tickets/$ARGUMENTS/exploration.md` for existing selectors to compare against
3. Read `templates/playwright-prompt.md` for browser exploration instructions

### Step 1.5: Check for claude-in-chrome (Lead Direct Browser Access)

Before spawning a browser teammate, check if `claude-in-chrome` MCP tools are available (requires Chrome extension connected via `claude --chrome`):

1. Call `mcp__claude-in-chrome__tabs_context_mcp`
2. If it succeeds (returns tab info): the lead can do browser work directly using MCP tools — no need to spawn a browser teammate. Use `navigate`, `find`, `read_page`, `javascript_tool` to gather selectors, then write `playwright-data.json` directly.
3. If it errors with "No Chrome extension connected": fall through to Step 2 (spawn browser teammate with CDP/playwright-cli).

**claude-in-chrome advantages for the lead:**
- No programmatic login needed (shares user's Chrome session)
- Natural-language element search: `find(query="login button")` instead of parsing snapshot trees
- `read_page(filter="interactive")` returns only interactive elements
- `javascript_tool` can enumerate all `data-testid` attributes

### Step 2: Spawn Browser Teammate

**IMPORTANT**: The spawn prompt is SELF-CONTAINED. Do NOT tell the agent to "read playwright-agent.md" — all instructions are inline.

Spawn browser teammate (sonnet):

```
You are the "browser" teammate for Jira ticket $ARGUMENTS.

MANDATORY OUTPUT — THIS IS YOUR #1 PRIORITY:
You MUST write `memory/tickets/$ARGUMENTS/playwright-data.json` before finishing.
Reserve your LAST 3 turns for writing output files.

CRITICAL: NEVER use `node -e` with Playwright's Node API. ALWAYS use Chrome CDP commands or playwright-cli.

═══════════════════════════════════════════════════════
STEP 1 — WRITE SKELETON (do this FIRST):
═══════════════════════════════════════════════════════

Write to memory/tickets/$ARGUMENTS/playwright-data.json:
{"pages":[],"new_selectors_needed":[],"reusable_selectors":[]}

═══════════════════════════════════════════════════════
STEP 1.5 — DETECT BROWSER TOOL:
═══════════════════════════════════════════════════════

    CDP="node .claude/skills/chrome-cdp/scripts/cdp.mjs"
    if $CDP list 2>/dev/null; then
        BROWSER_TOOL="cdp"
    else
        echo "CDP unavailable — using playwright-cli"
        BROWSER_TOOL="playwright-cli"
    fi

═══════════════════════════════════════════════════════
STEP 2 — OPEN BROWSER AND LOGIN (run these bash commands NOW):
═══════════════════════════════════════════════════════

Read environment from config/environments.json based on --env flag (default: stg):

    ENV_CONFIG=$(python3 -c "import json; cfg=json.load(open('config/environments.json')); print(json.dumps(cfg.get('<ENV>', cfg['stg'])))")
    APP_URL=$(echo "$ENV_CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin)['app_url'])")
    APP_USER=$(echo "$ENV_CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin)['user'])")
    APP_PASS=$(echo "$ENV_CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin)['password'])")

**If BROWSER_TOOL=cdp** — Open browser and login:

    TARGET=$($CDP open "$APP_URL" | grep -oP 'target:\s*\K\S+')
    $CDP click $TARGET "input[name='email'],input[type='email']"
    $CDP type $TARGET "$APP_USER"
    $CDP click $TARGET "input[name='password'],input[type='password']"
    $CDP type $TARGET "$APP_PASS"
    $CDP click $TARGET "button[type='submit']"
    sleep 3
    $CDP shot $TARGET

**If BROWSER_TOOL=playwright-cli** — Open browser and login:

    SESSION="pw-$(echo $TICKET_KEY | tr '[:upper:]' '[:lower:]')"
    playwright-cli -s=$SESSION open "$APP_URL"
    playwright-cli -s=$SESSION snapshot   # Find email/password/submit refs
    playwright-cli -s=$SESSION fill <email-ref> "$APP_USER"
    playwright-cli -s=$SESSION fill <password-ref> "$APP_PASS"
    playwright-cli -s=$SESSION click <submit-ref>
    sleep 3
    playwright-cli -s=$SESSION snapshot   # Verify login succeeded

Close "What's New" modal if present (try clicking close button or pressing Escape).

═══════════════════════════════════════════════════════
STEP 3 — NAVIGATE AND GATHER SELECTORS:
═══════════════════════════════════════════════════════

For EACH target page from triage.json:

**If BROWSER_TOOL=cdp:**

1. Navigate:
       $CDP nav $TARGET "<page_path>"
2. Screenshot:
       $CDP shot $TARGET
3. Get DOM structure:
       $CDP snap $TARGET

**If BROWSER_TOOL=playwright-cli:**

1. Navigate:
       playwright-cli -s=$SESSION goto "<page_url>"
2. Get DOM structure:
       playwright-cli -s=$SESSION snapshot
4. From the snapshot, extract for every interactive element:
   - data-testid attribute (preferred)
   - XPath selector
   - Text content
   - Aria labels
5. Test interactions where safe:
   - Click tabs/navigation to reveal sub-pages
   - Open dropdowns to see options
   - Screenshot each state change
6. Compare found locators against known selectors from exploration.md
   - Flag selectors that already exist (reuse)
   - Flag new selectors that need to be created
7. UPDATE playwright-data.json after EACH page (not at the end)

═══════════════════════════════════════════════════════
STEP 4 — WRITE FINAL OUTPUT:
═══════════════════════════════════════════════════════

Update memory/tickets/$ARGUMENTS/playwright-data.json with all data:
{
    "pages": [
        {
            "url": "/issues",
            "elements": [
                {
                    "name": "filterDropdown",
                    "type": "button",
                    "data_testid": "filter-dropdown",
                    "xpath": "//button[@data-testid='filter-dropdown']",
                    "text": "Filters",
                    "existing_selector": "filterBtn",
                    "needs_new_selector": false
                }
            ]
        }
    ],
    "new_selectors_needed": [
        { "name": "suggestedKey", "xpath": "//suggested/xpath", "data_testid": "found-testid", "target_file": "selectors/<feature_area>.json" }
    ],
    "reusable_selectors": [
        { "key": "existingKey", "file": "selectors/<file>.json" }
    ]
}

Update checkpoint: add "playwright" to completed_stages.

TRIAGE CONTEXT:
<paste triage.json>

EXPLORATION CONTEXT:
<paste exploration.md>
```

### Step 3: Wait and Validate

Wait for browser teammate to complete.

Validate `playwright-data.json`:
- Has at least one page entry
- Each page has at least one element
- new_selectors_needed is populated for any elements not found in existing selectors

### Step 4: Update Checkpoint

Update `memory/tickets/$ARGUMENTS/checkpoint.json`:
- Add "playwright" to `completed_stages`
- Set `current_stage` to "code-writer"
- Add `stage_outputs.playwright: "memory/tickets/$ARGUMENTS/playwright-data.json"`

### Step 5: Append Audit Log

Append to `memory/tickets/$ARGUMENTS/audit.md`:
```
### [<ISO-8601>] playwright-agent
**Action**: Gather locators for $ARGUMENTS
**Target**: memory/tickets/$ARGUMENTS/playwright-data.json
**Result**: Found <N> elements across <N> pages, <N> new selectors needed
**Details**: Pages visited: <page list>
```

### Step 6: Report to Dashboard

**DASHBOARD REPORT (MANDATORY)** — execute this bash command:
```bash
./scripts/report-to-dashboard.sh $ARGUMENTS playwright --status completed
```

### Step 7: Cleanup

Shut down the browser teammate and delete team `qa-browser-$ARGUMENTS`.

## Arguments

- `$ARGUMENTS` -- the Jira ticket key (e.g., OXDEV-123)
