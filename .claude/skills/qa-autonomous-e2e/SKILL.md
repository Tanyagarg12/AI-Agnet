---
name: qa-autonomous-e2e
description: Run the full autonomous E2E test pipeline for a Jira ticket using Agent Teams. Handles triage, framework exploration, Playwright browser locator gathering, test implementation, test execution with debug loops, and MR creation.
disable-model-invocation: true
argument-hint: "[ticket-key]"
---

# Autonomous E2E Test Pipeline (Agent Teams)

Run the complete Jira-to-MR pipeline for creating E2E Playwright tests. The pipeline operates on a single ticket: triage, explore, gather locators, write test, run test, debug if needed, and create MR.

## Usage

```
/qa-autonomous-e2e OXDEV-123
/qa-autonomous-e2e OXDEV-123 --auto
```

## Flags

Parse `$ARGUMENTS` for flags before processing:
- **`--auto`**: Skip plan approval for the code-writer phase. The developer teammate runs without requiring the user to approve its implementation plan. Use this for fully unattended pipeline runs.
- **`--watch`**: Re-check the Jira ticket between pipeline phases. If the ticket description or requirements changed, re-triage and restart affected stages. If ticket is closed/cancelled, abort the pipeline gracefully.
- **`--env dev|stg`**: Target environment for browser exploration and test execution. Default: `stg`. Reads credentials from `config/environments.json`.

Extract the ticket key (first word) and flags from `$ARGUMENTS`. For example, `OXDEV-123 --auto --watch --env dev` means ticket key is `OXDEV-123`, auto mode is enabled, watch mode is enabled, and target environment is dev.

---

## Telemetry Recording

Track only actual agent work time — not idle/waiting time. Record the start time immediately before spawning each teammate and the end time immediately after the teammate completes. Cap `duration_seconds` at **3600** (1 hour) — if the wall-clock difference exceeds 3600, record 3600. This prevents inflated durations from network delays, retries, or queue time.

Write to `memory/tickets/$ARGUMENTS/telemetry.json`:

```json
{
    "stages": {
        "explorer": { "started_at": "...", "completed_at": "...", "duration_seconds": 45, "output_size_bytes": 2100, "model": "sonnet", "max_turns": 25, "tokens_used": 15000 },
        "playwright": { "started_at": "...", "completed_at": "...", "duration_seconds": 60, "output_size_bytes": 3400, "model": "sonnet", "max_turns": 40, "tokens_used": 22000 }
    }
}
```

Record timestamps using: `date -u +%Y-%m-%dT%H:%M:%SZ`
Get output file size using: `wc -c < <output-file>`
Compute `duration_seconds` as: `min(completed_at - started_at, 3600)`
Estimate `tokens_used` from the JSONL stage log: `wc -c < memory/tickets/$ARGUMENTS/stage-logs/<stage>.jsonl` (rough proxy: ~4 chars per token, multiply output_size_bytes by 3 for input+output). If no JSONL log exists, omit the field.
Include telemetry in each dashboard report call.

---

## Before Starting -- Check for Checkpoint

Before running any agents, check if `memory/tickets/$ARGUMENTS/checkpoint.json` exists.

If it exists:
1. Read the checkpoint file
2. Read `completed_stages` to see what has already run
3. Inform the user: "Found existing checkpoint for $ARGUMENTS. Stages completed: [list]. Resuming from [next stage]."
4. Skip all completed stages when creating the task list (mark them as already completed)
5. Load stage outputs from the paths in `stage_outputs` to include as context in teammate spawn prompts

If it does NOT exist:
1. Create directory `memory/tickets/$ARGUMENTS/`
2. Start from Phase 1 (Triage)

---

## Start Relay Daemon

Before running any pipeline phases, start the local relay daemon to enable real-time log streaming and dashboard command delivery:

```bash
mkdir -p memory/tickets/$ARGUMENTS/stage-logs
node scripts/agent-relay.js --ticket $ARGUMENTS --dashboard ${DASHBOARD_WS_URL:-ws://52.51.14.138:3459/ws} &
RELAY_PID=$!
echo "$RELAY_PID" > memory/tickets/$ARGUMENTS/relay.pid
```

The relay:
- Streams JSONL log files from `stage-logs/` to the dashboard in real-time
- Receives commands from the dashboard and writes them to `memory/tickets/$ARGUMENTS/inbox.json`
- Runs in the background until the pipeline completes

If the relay fails to start (e.g., dashboard unreachable), continue the pipeline without it — the existing HTTP-based reporting (`report-to-dashboard.sh`) still works as fallback.

---

## Phase 1: Triage (Lead does this directly)

The lead performs triage directly -- this is simple classification work that does not need a separate teammate.

**Reset dashboard pipeline** (if restarting a ticket that already ran):
```bash
# Look up existing pipeline by EXACT ticket key match and delete it so stages start fresh
PIPELINE_ID=$(curl -s "${DASHBOARD_URL:-http://52.51.14.138:3459}/api/e2e-agent/pipelines?search=$ARGUMENTS" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
key='$ARGUMENTS'
match=[p for p in d.get('pipelines',[]) if p.get('ticketKey')==key]
print(match[0]['id'] if match else '')
" 2>/dev/null)
if [ -n "$PIPELINE_ID" ]; then
    curl -s -X DELETE "${DASHBOARD_URL:-http://52.51.14.138:3459}/api/e2e-agent/pipelines/$PIPELINE_ID" 2>/dev/null || true
    echo "Reset dashboard pipeline $PIPELINE_ID for $ARGUMENTS"
fi
```

**Ensure E2E framework is up to date** (MANDATORY before any git operations):
```bash
cd $E2E_FRAMEWORK_PATH && git fetch origin developmentV2
```
This ensures `developmentV2` is current so branches, diffs, and MRs are based on the latest code. Return to project dir after:
```bash
cd $PROJECT_ROOT
```

**Record triage start time** (for telemetry):
```bash
TRIAGE_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

1. Read the Jira ticket using `acli` (via `/jira-api` skill)
2. Read `memory/framework-catalog.md` for known framework structure
3. Follow the classification logic in `.claude/agents/triage-agent.md`:
   - Classify feature area: issues, sbom, dashboard, policies, settings, connectors, reports, cbom, users
   - Classify test type: ui, api, mixed
   - Assess complexity: S, M, L
   - Check if baseline data is needed (needs_baseline)
   - Identify target pages from the ticket description
   - Determine the org name to use for testing
4. Write triage output to `memory/tickets/$ARGUMENTS/triage.json` (schema in `templates/triage-output.md`)
5. Write initial checkpoint to `memory/tickets/$ARGUMENTS/checkpoint.json`:
   ```json
   {
     "ticket_key": "$ARGUMENTS",
     "pipeline": ["triage", "explorer", "playwright", "code-writer", "test-runner", "cross-env-check", "pr"],
     "completed_stages": ["triage"],
     "current_stage": "explorer",
     "status": "in_progress",
     "last_updated": "<ISO-8601>",
     "stage_outputs": {
       "triage": "memory/tickets/$ARGUMENTS/triage.json"
     },
     "error": null,
     "debug_cycles": 0
   }
   ```
6. Append to audit log `memory/tickets/$ARGUMENTS/audit.md`
7. Add `ai-in-progress` label to the Jira ticket:
   ```bash
   acli jira workitem edit --key "$ARGUMENTS" --labels "ai-in-progress" --yes
   ```
8. **DASHBOARD REPORT (MANDATORY — EXECUTE BEFORE PROCEEDING TO NEXT PHASE):**
   ```bash
   ./scripts/report-to-dashboard.sh $ARGUMENTS triage
   ```
9. **Compute and store ticket hash** for `--watch` mode:
   After writing triage.json, compute a hash of the ticket's description + summary and store it as `ticket_hash` in triage.json. Use python3:
   ```bash
   python3 -c "
   import json, hashlib
   with open('memory/tickets/$ARGUMENTS/triage.json', 'r+') as f:
       data = json.load(f)
       # Hash is computed from the Jira description + summary stored in triage.json
       hash_input = (data.get('description', '') + data.get('summary', '')).encode('utf-8')
       data['ticket_hash'] = hashlib.md5(hash_input).hexdigest()
       f.seek(0)
       json.dump(data, f, indent=4)
       f.truncate()
   # Verify: re-read and confirm hash matches content
   with open('memory/tickets/$ARGUMENTS/triage.json') as f:
       verify = json.load(f)
       verify_hash = hashlib.md5((verify.get('description', '') + verify.get('summary', '')).encode('utf-8')).hexdigest()
       assert verify['ticket_hash'] == verify_hash, f'Hash mismatch after write: stored={verify[\"ticket_hash\"]}, computed={verify_hash}'
       print(f'Hash verified: {verify_hash}')
   "
   ```
   CRITICAL: The triage agent MUST store the raw Jira `description` field in triage.json (in addition to the `summary` field) BEFORE the hash is computed. The hash must be computed from the SAME data stored in triage.json — never from a separate Jira read. If the hash and content get out of sync, `--watch` will fail to detect changes.

10. **Check for interactive notes in ticket description** (MANDATORY):
    After writing triage.json, check if the ticket description contains notes/instructions addressed to the AI that require user input. Look for:
    - Parenthesized instructions: `(note for AI: ...)`, `(ask the user for ...)`
    - Placeholder tokens: `<YOUR_TOKEN>`, `{PROJECT_ID}`, `<ask user>`
    - Explicit asks: "ask the user for...", "provide the following..."
    - References to tokens, project IDs, URLs, credentials, or config values not available in env vars

    If found, **pause and prompt the user**:
    ```bash
    python3 -c "
    import json
    with open('memory/tickets/$ARGUMENTS/triage.json') as f:
        data = json.load(f)
    desc = data.get('description', '')
    # Check for AI-directed notes
    import re
    patterns = [
        r'\(note for (?:AI|ai|agent).*?\)',
        r'\(ask (?:the )?user.*?\)',
        r'\(provide .*?\)',
        r'<YOUR[_\s].*?>',
        r'\{[A-Z_]+\}',
        r'<ask[ _]user>',
        r'ask (?:the )?user (?:for|to provide)',
    ]
    matches = []
    for p in patterns:
        matches.extend(re.findall(p, desc, re.IGNORECASE))
    if matches:
        print('USER_INPUT_REQUIRED')
        for m in matches:
            print(f'  - {m}')
    else:
        print('NO_INPUT_NEEDED')
    "
    ```

    If `USER_INPUT_REQUIRED` is detected:
    - Write `memory/tickets/$ARGUMENTS/user-input-required.json` with the detected notes and questions
    - **Use AskUserQuestion tool** to present the detected notes and ask the user to provide the required values
    - Store answers in `memory/tickets/$ARGUMENTS/user-input-answers.json`
    - Update triage.json with any provided values (e.g., add `gitlab_token`, `project_id` etc. to a `user_provided` field)
    - Then continue the pipeline with the user-provided context

---

## Watch Check (between phases)

If `--watch` flag is set, run the watch check before starting the next phase:

1. Run: `./scripts/watch-check.sh <TICKET-KEY>`
   (Extract the ticket key from `$ARGUMENTS` — first word, without flags)
2. Parse the JSON output
3. Decision matrix:
   - `changed: false` — continue to next phase
   - `status_closed: true` — abort pipeline:
     - Update checkpoint: status `"aborted"`, error `"Ticket closed/cancelled"`
     - Remove `ai-in-progress` label:
       ```bash
       acli jira workitem edit --key "<TICKET-KEY>" --remove-labels "ai-in-progress" --yes
       ```
     - Report to dashboard:
       ```bash
       ./scripts/report-to-dashboard.sh <TICKET-KEY> finalize --status failed
       ```
     - Stop the pipeline — do NOT proceed to the next phase
   - `change_type: "description"` — significant change:
     - Log: "Ticket description changed — re-triaging"
     - Re-run triage (Phase 1) to update triage.json with new data and hash
     - Update checkpoint: remove all stages after triage from `completed_stages`
     - Continue from explorer (Phase 2) — downstream data is now stale
   - `change_type: "summary"` or `change_type: "priority"` — cosmetic change:
     - Update triage.json with new summary/priority (read the current Jira data and patch triage.json)
     - Continue to next phase (no restart needed)

Insert this check at these transition points:
- Between Phase 1 (Triage) and Phase 2 (Explorer)
- Between Phase 2 (Explorer) and Phase 3 (Playwright)
- Between Phase 3 (Playwright) and Phase 4 (Code-Writer)
- Between Phase 4 (Code-Writer) and Phase 5+6 (Test+Debug)
- Between Phase 5+6 (Test+Debug) and Phase 7 (PR)

**WATCH CHECK (if `--watch` flag is set):** Run `./scripts/watch-check.sh <TICKET-KEY>` and follow the decision matrix above before proceeding to Phase 2.

---

## Inbox Check (between phases — ALWAYS run)

Between EVERY pipeline phase, check for commands from the dashboard. This runs unconditionally (not just with `--watch`).

1. **Check local inbox** (delivered by relay daemon — near-instant):
   ```bash
   INBOX_FILE="memory/tickets/<TICKET-KEY>/inbox.json"
   if [ -f "$INBOX_FILE" ]; then
       COMMANDS=$(python3 -c "import json; data=json.load(open('$INBOX_FILE')); print(json.dumps(data.get('commands',[])))")
   else
       COMMANDS="[]"
   fi
   ```

2. **Fallback: check remote dashboard** (if relay is down or inbox is empty):
   ```bash
   if [ "$COMMANDS" = "[]" ]; then
       COMMANDS=$(./scripts/check-inbox.sh <TICKET-KEY>)
   fi
   ```

3. **Process each command** (in order):
   - **`abort`**: Update checkpoint status to `"aborted"`, remove `ai-in-progress` label, report to dashboard, kill relay, stop pipeline.
   - **`skip_stage`**: Mark the target stage as "skipped" in checkpoint, set current_stage to next stage, continue.
   - **`retry_stage`**: Clear that stage's output files, remove from completed_stages in checkpoint, re-run that phase.
   - **`approve`**: If pipeline is waiting for approval (see Approval Flow below), proceed with the approved stage.
   - **`reject`**: Read `payload.reason`, log it, adjust the plan/approach, re-submit for approval.
   - **`feedback`**: Append `payload.message` to `memory/tickets/<KEY>/user-feedback.md`. Include this file's contents in the NEXT agent spawn prompt as "User Feedback" context.
   - **`add_hint`**: Append `payload.hint` to `memory/tickets/<KEY>/hints.md`. Include in next browser/code-writer agent prompts.
   - **`edit_context`**: Update triage.json or checkpoint.json with the new field/value from payload.
   - **`priority_change`**: Update triage.json priority field.

4. **Acknowledge each processed command**:
   ```bash
   ./scripts/ack-command.sh <command-id> completed
   ```

5. **Clear local inbox** after processing all commands:
   ```bash
   echo '{"commands":[]}' > memory/tickets/<TICKET-KEY>/inbox.json
   ```

Insert this check at the same transition points as Watch Check (runs AFTER watch check if both apply).

---

## Approval Flow (non-`--auto` mode)

When `--auto` is NOT set and the pipeline reaches a decision point that normally requires user confirmation (e.g., code-writer implementation plan), use the dashboard for approval instead of blocking the terminal:

1. **Write the pending plan**:
   ```bash
   # Write plan details to a file the dashboard can display
   echo '<plan content>' > memory/tickets/<TICKET-KEY>/pending-plan.json
   ```

2. **Report to dashboard with approval request**:
   ```bash
   ./scripts/report-to-dashboard.sh <TICKET-KEY> code-writer --status in_progress \
       --needs-human --notification-type approval_needed \
       --notification-msg "Implementation plan ready for review"
   ```

3. **Wait for response** — poll inbox every 15 seconds:
   ```bash
   while true; do
       # Check local inbox first (relay delivers near-instantly)
       if [ -f "memory/tickets/<TICKET-KEY>/inbox.json" ]; then
           RESPONSE=$(python3 -c "
   import json
   data = json.load(open('memory/tickets/<TICKET-KEY>/inbox.json'))
   for cmd in data.get('commands', []):
       if cmd.get('type') in ('approve', 'reject'):
           print(json.dumps(cmd))
           break
   " 2>/dev/null)
           if [ -n "$RESPONSE" ]; then break; fi
       fi
       # Fallback: poll remote dashboard
       RESPONSE=$(./scripts/check-inbox.sh <TICKET-KEY> | python3 -c "
   import json, sys
   for cmd in json.load(sys.stdin):
       if cmd.get('command_type') in ('approve', 'reject'):
           print(json.dumps(cmd))
           break
   " 2>/dev/null)
       if [ -n "$RESPONSE" ]; then break; fi
       sleep 15
   done
   ```

4. **Process response**:
   - `approve` → acknowledge command, proceed to spawn code-writer
   - `reject` → read `payload.reason`, log it, adjust plan, re-submit for approval (max 3 iterations, then abort)

When `--auto` IS set, skip the approval flow entirely and proceed directly.

---

## Phase 2+3: Explorer + Playwright (Parallel)

**DASHBOARD REPORT (MANDATORY — report BEFORE spawning agents):**
```bash
./scripts/report-stage.sh $ARGUMENTS explorer --status in_progress
./scripts/report-stage.sh $ARGUMENTS playwright --status in_progress
```

Spawn BOTH teammates at the same time. They run concurrently.

Create team `qa-e2e-$ARGUMENTS` (e.g., `qa-e2e-OXDEV-123`).

Spawn analyst teammate (sonnet):

```
You are the "analyst" teammate for Jira ticket $ARGUMENTS.

MANDATORY OUTPUT — THIS IS YOUR #1 PRIORITY:
You MUST write `memory/tickets/$ARGUMENTS/exploration.md` before finishing.
Your VERY FIRST action must be writing a skeleton exploration.md (even with placeholder text).
Then UPDATE it as you discover things. If you run out of turns without this file, the pipeline is BLOCKED.

YOUR TASK: Explore the E2E test framework to find relevant patterns, actions, selectors, and similar tests.

INSTRUCTIONS:
1. Write skeleton `memory/tickets/$ARGUMENTS/exploration.md` NOW (before anything else).
2. Read `.claude/agents/explorer-agent.md` for exploration instructions.
3. Read `memory/tickets/$ARGUMENTS/triage.json` for ticket context.
4. Read `memory/framework-catalog.md` for framework overview.

EXPLORATION:
- Navigate to the framework/ directory (use CLAUDE_CODE_ADDITIONAL_DIRECTORIES)
- Find similar existing tests in tests/UI/<feature_area>/
- Find relevant action modules in actions/
- Find relevant selector files in selectors/
- Study the test patterns: imports, hooks, serial mode, login flow
- Identify reusable action functions for the target pages
- Check env files for required environment variables (NOTE: env files use colon syntax `KEY: "value"`, NOT shell format — do NOT try to `source` them)
- UPDATE `memory/tickets/$ARGUMENTS/exploration.md` with findings as you go
- Update checkpoint: add "explorer" to completed_stages

PROGRESS REPORTING — after each major discovery, update exploration.md THEN run:
    ./scripts/report-to-dashboard.sh $ARGUMENTS explorer

TRIAGE CONTEXT:
<paste full triage.json content here>
```

Wait for analyst to complete.

**VERIFY OUTPUT (CRITICAL — agents often fail to write output files):**

If `memory/tickets/$ARGUMENTS/exploration.md` is missing or empty, write a fallback DIRECTLY (do not re-spawn):
```bash
if [ ! -s memory/tickets/$ARGUMENTS/exploration.md ]; then
    echo -e "# Exploration: $ARGUMENTS\n\n## Note\nExplorer agent completed without writing output. Check audit.md for partial findings.\nProceed with code-writer using triage.json context only." > memory/tickets/$ARGUMENTS/exploration.md
fi
```

**DASHBOARD REPORT (MANDATORY — EXECUTE BEFORE PROCEEDING TO NEXT PHASE):**
```bash
./scripts/report-to-dashboard.sh $ARGUMENTS explorer --status completed
```

**WATCH CHECK (if `--watch` flag is set):** Run `./scripts/watch-check.sh <TICKET-KEY>` and follow the decision matrix from the "Watch Check" section above before proceeding.

---

### Playwright (Spawn browser teammate IN PARALLEL — do NOT wait for explorer)

Spawn browser teammate (sonnet) to gather locators from the live application. This runs concurrently with the explorer above.

**IMPORTANT**: The spawn prompt below is SELF-CONTAINED. It uses triage.json only (no exploration.md reference since explorer runs in parallel). Do NOT tell the agent to "read playwright-agent.md" — all instructions are inline.

```
You are the "browser" teammate for Jira ticket $ARGUMENTS.

MANDATORY OUTPUT — THIS IS YOUR #1 PRIORITY:
You MUST write `memory/tickets/$ARGUMENTS/playwright-data.json` before finishing.
Reserve your LAST 3 turns for writing output files. Partial data is infinitely better than no data.

CRITICAL: NEVER use `node -e` with Playwright's Node API. ALWAYS use playwright-cli commands.
playwright-cli is already installed globally. Do NOT run npm install.

═══════════════════════════════════════════════════════
STEP 1 — WRITE SKELETON FILE (do this FIRST, before anything else):
═══════════════════════════════════════════════════════

Write to memory/tickets/$ARGUMENTS/playwright-data.json:
{"selectors":{},"values_captured":{},"screenshots":[],"navigation_flow":[],"flow_validation":{"status":"pending"}}

═══════════════════════════════════════════════════════
STEP 2 — READ CONTEXT (quick — spend at most 2 turns here):
═══════════════════════════════════════════════════════

Read these 2 files:
1. memory/tickets/$ARGUMENTS/triage.json — for target pages
2. memory/tickets/$ARGUMENTS/exploration.md — for the "Playwright Exploration Prompt" section (pages to visit, elements to inspect, values to capture)

DO NOT read any other files. All browser instructions are below.

═══════════════════════════════════════════════════════
STEP 3 — OPEN BROWSER AND LOGIN (run these bash commands NOW):
═══════════════════════════════════════════════════════

Run these commands in sequence. The browser stays open between calls:

    playwright-cli open "$STAGING_URL"

Then wait 2-3 seconds and run:

    playwright-cli fill "input[name='email'],input[type='email']" "$STAGING_USER"
    playwright-cli fill "input[name='password'],input[type='password']" "$STAGING_PASSWORD"
    playwright-cli click "button[type='submit']"

Then wait for login to complete and take a screenshot:

    playwright-cli screenshot

If you see a "What's New" modal, close it:
    playwright-cli click "button:has-text('Close')" || playwright-cli click "[aria-label='Close']" || playwright-cli press "Escape"

═══════════════════════════════════════════════════════
STEP 4 — NAVIGATE AND GATHER SELECTORS:
═══════════════════════════════════════════════════════

For EACH target page from triage.json:

1. Navigate:
       playwright-cli goto "$STAGING_URL<page_path>"
2. Screenshot:
       playwright-cli screenshot
3. Get DOM structure:
       playwright-cli snapshot
4. From the snapshot output, extract selectors for every interactive element:
   - Buttons, filters, tables, menus, tabs, inputs, toggles
   - Priority: data-testid > data-cy > semantic role+text > structural XPath
   - MANDATORY FORMAT: EVERY selector MUST have a pipe-separated fallback: "//*[@data-testid='x'] | //button[text()='y']"
   - NEVER write a selector without ` | ` — always include a text-based or structural XPath as fallback
5. Capture current values for assertions:
   - Counters, badges, table row counts, dropdown options
6. Test interactions where safe:
   - Click tabs to reveal sub-pages, open dropdowns
   - Screenshot each state change
7. UPDATE playwright-data.json after EACH page (not at the end)

═══════════════════════════════════════════════════════
STEP 5 — VALIDATE THE FLOW:
═══════════════════════════════════════════════════════

After gathering all selectors, replay the full navigation flow end-to-end:
1. Execute each step in your navigation_flow using playwright-cli
2. Verify each element exists (snapshot + screenshot)
3. Record results in flow_validation

═══════════════════════════════════════════════════════
STEP 6 — WRITE FINAL OUTPUT:
═══════════════════════════════════════════════════════

Update memory/tickets/$ARGUMENTS/playwright-data.json with all gathered data:
{
  "selectors": { "elementName": "//*[@data-testid='x'] | //fallback" },
  "values_captured": { "issueCount": "142", "filterOptions": ["Critical","High"] },
  "screenshots": ["login-complete", "page-loaded"],
  "navigation_flow": [
    {"action": "navigate", "target": "/issues"},
    {"action": "click", "selector": "menuItem", "description": "Open page"}
  ],
  "flow_validation": { "status": "pass", "steps_validated": 4, "steps_passed": 4, "steps_failed": 0, "failures": [] }
}

Update checkpoint: add "playwright" to completed_stages.

PROGRESS REPORTING — after each page explored, update playwright-data.json THEN run:
    ./scripts/report-to-dashboard.sh $ARGUMENTS playwright

TRIAGE + EXPLORATION CONTEXT:
<paste triage.json + exploration.md>
```

Wait for browser to complete.

**VERIFY OUTPUT (CRITICAL — agents often fail to write output files):**

If `memory/tickets/$ARGUMENTS/playwright-data.json` is missing or empty, write a fallback DIRECTLY (do not re-spawn):
```bash
if [ ! -s memory/tickets/$ARGUMENTS/playwright-data.json ]; then
    echo '{"selectors":{},"values_captured":{},"screenshots":[],"navigation_flow":[],"flow_validation":{"status":"skipped","details":"Agent completed without writing output"}}' > memory/tickets/$ARGUMENTS/playwright-data.json
fi
```

**VERIFY FLOW VALIDATION**: Read `playwright-data.json` and check `flow_validation.status`.
If `status` is `"fail"`, log a warning — the code-writer should be aware that some steps may need adjustment.

**DASHBOARD REPORT (MANDATORY — EXECUTE BEFORE PROCEEDING TO NEXT PHASE):**
```bash
./scripts/report-to-dashboard.sh $ARGUMENTS playwright --status completed
```

**WATCH CHECK (if `--watch` flag is set):** Run `./scripts/watch-check.sh <TICKET-KEY>` and follow the decision matrix from the "Watch Check" section above before proceeding.

---

## Phase 4: Code Writer (Spawn developer teammate)

**DASHBOARD REPORT (MANDATORY — report BEFORE spawning agent):**
```bash
./scripts/report-stage.sh $ARGUMENTS code-writer --status in_progress
```

Spawn developer teammate (opus) to write the test, actions, and selectors.

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
    ## Files Modified
    (pending)
    ## Commits
    (pending)
    ## Test Summary
    (pending)

STEP 2 — Read context:
1. Read `.claude/agents/code-writer-agent.md` for implementation instructions.
2. Read `memory/tickets/$ARGUMENTS/triage.json` for ticket context.
3. Read `memory/tickets/$ARGUMENTS/exploration.md` for framework patterns.
4. Read `memory/tickets/$ARGUMENTS/playwright-data.json` for locators.
5. Read `templates/test-file.md` for test scaffold template.

STEP 3 — Repository setup:
- Work in the framework/ directory
- Create branch: test/$ARGUMENTS-<short-slug>
- Ensure branch is based on developmentV2

STEP 4 — Implementation:
- Create test file: tests/UI/<feature_area>/<testName>.test.js
- Add/update action functions in actions/<feature_area>.js (prefer reuse)
- Add/update selector entries in selectors/<feature_area>.json (prefer reuse)
- Follow framework conventions: CommonJS, serial mode, setHooks, numbered tests
- Use existing patterns from exploration.md as reference
- COMMIT: `$ARGUMENTS: Add E2E test for <summary>`
- Push: `git push -u origin test/$ARGUMENTS-<short-slug>`
- UPDATE `memory/tickets/$ARGUMENTS/implementation.md` with actual file paths and branch name
- WRITE `memory/tickets/$ARGUMENTS/code-writer-output.json` (REQUIRED for dashboard diffs):
  After your final commit + push, run these commands in the framework dir:
      git rev-parse --abbrev-ref HEAD                    # → "branch" field
      git log developmentV2..HEAD --pretty=format:"%h"   # → "commits" array
      git diff developmentV2...HEAD                      # → top-level "diff" field
      git diff --numstat developmentV2...HEAD             # → per-file stats
      git diff --name-status developmentV2...HEAD         # → files_created/files_modified
  Write JSON with EXACT field names: "branch" (NOT branch_name), "commits" (array of hashes), "diff" (top-level FULL combined unified diff), "files_created" (A entries), "files_modified" (M entries), test_file, files, files_count, lines_added, lines_deleted, test_steps, feature_doc.
  CRITICAL: The "diff" field in each file MUST be the RAW output of `git diff` — NOT a summary.
  WRONG: "diff": "Added 7 new selectors: foo, bar, baz"
  WRONG: "diff": "...(114 lines, serial test with 10 steps)"
  RIGHT: "diff": "diff --git a/selectors/x.json b/selectors/x.json\n--- a/selectors/x.json\n+++ b/selectors/x.json\n@@ -1,3 +1,10 @@\n+..."
  The dashboard parses unified diff format to render colored +/- lines. Summaries break it.
- Update checkpoint: add "code-writer" to completed_stages

PROGRESS REPORTING — after branch creation, after writing test file, and after commit, update implementation.md THEN run:
    ./scripts/report-to-dashboard.sh $ARGUMENTS code-writer

ALL CONTEXT:
<paste triage.json + exploration.md + playwright-data.json>
```

If `--auto` flag WAS passed: skip plan approval — let the developer proceed immediately.

If `--auto` flag was NOT passed: **use the dashboard approval flow** before spawning the code-writer teammate:

1. Write the implementation plan to a file for the dashboard to display:
   ```bash
   python3 -c "
   import json
   plan = {
       'ticket_key': '$ARGUMENTS',
       'stage': 'code-writer',
       'plan_summary': '<brief description of what will be implemented>',
       'test_file': '<planned test file path>',
       'feature_area': '<feature>',
       'steps': ['Create selectors', 'Write action functions', 'Write test file', 'Commit and push']
   }
   with open('memory/tickets/$ARGUMENTS/pending-plan.json', 'w') as f:
       json.dump(plan, f, indent=2)
   "
   ```

2. Report to dashboard with approval request:
   ```bash
   ./scripts/report-to-dashboard.sh $ARGUMENTS code-writer --status in_progress \
       --needs-human --notification-type approval_needed \
       --notification-msg "Implementation plan ready for review — approve or reject from the dashboard"
   ```

3. Wait for dashboard response (poll inbox every 15 seconds):
   ```bash
   echo "Waiting for dashboard approval... (check http://52.51.14.138:3459)"
   while true; do
       INBOX_FILE="memory/tickets/$ARGUMENTS/inbox.json"
       if [ -f "$INBOX_FILE" ]; then
           RESPONSE=$(python3 -c "
   import json, sys
   try:
       data = json.load(open('$INBOX_FILE'))
       for cmd in data.get('commands', []):
           if cmd.get('type') in ('approve', 'reject'):
               print(json.dumps(cmd))
               break
   except: pass
   " 2>/dev/null)
           if [ -n "$RESPONSE" ]; then
               CMD_TYPE=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type',''))")
               CMD_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")
               if [ "$CMD_TYPE" = "approve" ]; then
                   echo "Plan approved from dashboard!"
                   ./scripts/ack-command.sh "$CMD_ID" completed "Plan approved"
                   break
               elif [ "$CMD_TYPE" = "reject" ]; then
                   REASON=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('payload',{}).get('reason','No reason given'))")
                   echo "Plan rejected: $REASON"
                   ./scripts/ack-command.sh "$CMD_ID" completed "Plan rejected"
                   # TODO: adjust plan based on reason and re-submit
                   break
               fi
           fi
       fi
       # Also check remote dashboard as fallback
       REMOTE=$(./scripts/check-inbox.sh $ARGUMENTS 2>/dev/null)
       REMOTE_CMD=$(echo "$REMOTE" | python3 -c "
   import json, sys
   try:
       for cmd in json.load(sys.stdin):
           if cmd.get('commandType') in ('approve', 'reject'):
               print(json.dumps(cmd))
               break
   except: pass
   " 2>/dev/null)
       if [ -n "$REMOTE_CMD" ]; then
           CMD_TYPE=$(echo "$REMOTE_CMD" | python3 -c "import json,sys; print(json.load(sys.stdin).get('commandType',''))")
           if [ "$CMD_TYPE" = "approve" ] || [ "$CMD_TYPE" = "reject" ]; then
               echo "Response received from dashboard: $CMD_TYPE"
               break
           fi
       fi
       sleep 15
   done
   ```

4. If approved, proceed to spawn the developer teammate. If rejected, adjust the plan and re-submit (or abort after 3 rejections).

Wait for developer to complete.

**VERIFY OUTPUT (CRITICAL — agents often fail to write output files):**

Check BOTH files exist and are non-empty. If missing, write fallbacks DIRECTLY (do not re-spawn):

```bash
# 1. implementation.md — if missing, generate from git log
if [ ! -s memory/tickets/$ARGUMENTS/implementation.md ]; then
    cd $E2E_FRAMEWORK_PATH
    BRANCH=$(git branch --show-current)
    FILES=$(git diff --name-only developmentV2...HEAD 2>/dev/null || echo "(unknown)")
    COMMITS=$(git log --oneline developmentV2...HEAD 2>/dev/null || echo "(unknown)")
    cat > memory/tickets/$ARGUMENTS/implementation.md << IMPL_EOF
# Implementation: $ARGUMENTS

## Files Created
$FILES

## Commits
$COMMITS

## Branch
$BRANCH

## Note
Code-writer agent completed without writing implementation.md. Data above generated from git.
IMPL_EOF
fi

# 2. code-writer-output.json — if missing, generate from git diff
if [ ! -s memory/tickets/$ARGUMENTS/code-writer-output.json ]; then
    cd $E2E_FRAMEWORK_PATH
    BRANCH=$(git branch --show-current)
    python3 -c "
import json, subprocess, os
branch = '$BRANCH'
result = subprocess.run(['git', 'diff', '--numstat', 'developmentV2...HEAD'], capture_output=True, text=True)
files = []
for line in result.stdout.strip().split('\n'):
    if not line: continue
    parts = line.split('\t')
    if len(parts) == 3:
        added, deleted, path = parts
        diff_result = subprocess.run(['git', 'diff', 'developmentV2...HEAD', '--', path], capture_output=True, text=True)
        files.append({'path': path, 'type': 'unknown', 'added': int(added) if added.isdigit() else 0, 'deleted': int(deleted) if deleted.isdigit() else 0, 'diff': diff_result.stdout[:5000]})
data = {'test_file': '', 'branch_name': branch, 'files': files, 'files_count': len(files), 'lines_added': sum(f['added'] for f in files), 'lines_deleted': sum(f['deleted'] for f in files), 'test_steps': 0, 'uses_baseline': False, 'new_actions': [], 'new_selectors': []}
with open('memory/tickets/$ARGUMENTS/code-writer-output.json', 'w') as f:
    json.dump(data, f, indent=4)
" 2>/dev/null || echo '{"test_file":"","branch_name":"","files":[],"files_count":0,"lines_added":0,"lines_deleted":0}' > memory/tickets/$ARGUMENTS/code-writer-output.json
fi
```

**DASHBOARD REPORT (MANDATORY — EXECUTE BEFORE PROCEEDING TO NEXT PHASE):**
```bash
./scripts/report-to-dashboard.sh $ARGUMENTS code-writer --status completed
```

**WATCH CHECK (if `--watch` flag is set):** Run `./scripts/watch-check.sh <TICKET-KEY>` and follow the decision matrix from the "Watch Check" section above before proceeding.

---

## Phase 4.5: Validation (Spawn validator teammate)

**DASHBOARD REPORT (MANDATORY — report BEFORE spawning agent):**
```bash
./scripts/report-stage.sh $ARGUMENTS validator --status in_progress
```

Spawn validator teammate (haiku):

```
You are the "validator" teammate for Jira ticket $ARGUMENTS.

MANDATORY OUTPUT:
You MUST write `memory/tickets/$ARGUMENTS/validation-report.json` before finishing.

YOUR TASK: Validate the code-writer's output against framework conventions and produce a quality checklist.

INSTRUCTIONS:
1. Write skeleton validation-report.json NOW.
2. Read `.claude/agents/validator-agent.md` for validation instructions.
3. Read `memory/tickets/$ARGUMENTS/implementation.md` for file paths.
4. Read `memory/tickets/$ARGUMENTS/code-writer-output.json` for diffs.
5. Run all checks, auto-fix where possible (max 2 attempts), report results.

IMPLEMENTATION CONTEXT:
<paste implementation.md>
```

Wait for validator to complete. Record telemetry.

**VERIFY OUTPUT**: If `validation-report.json` missing, write fallback with all checks as "unknown".

**Check for structural failures**: Read `validation-report.json`. If `status` is `"failed"`, stop pipeline — add `ai-failed` label and comment explaining the structural issue.

**DASHBOARD REPORT:**
```bash
./scripts/report-to-dashboard.sh $ARGUMENTS validator --status completed
```

---

## Phase 5+6: Test Runner + Debug (Parallel)

**DASHBOARD REPORT (MANDATORY — report BEFORE spawning agents):**
```bash
./scripts/report-stage.sh $ARGUMENTS test-runner --status in_progress
./scripts/report-stage.sh $ARGUMENTS debug --status in_progress
```

Spawn **both** the tester and debug teammates at the same time. The debug agent polls for test results and starts fixing as soon as failures appear — no orchestrator bottleneck.

**Spawn tester teammate (sonnet):**

```
You are the "tester" teammate for Jira ticket $ARGUMENTS.

MANDATORY OUTPUT — THIS IS YOUR #1 PRIORITY:
You MUST write `memory/tickets/$ARGUMENTS/test-results.json` before finishing.
Even if the test crashes or errors out, you MUST still write this file with status "failed" and error details.

STEP 1 — Read context:
1. Read `.claude/agents/test-runner-agent.md` for test execution instructions.
2. Read `memory/tickets/$ARGUMENTS/triage.json` for environment config.
3. Read `memory/tickets/$ARGUMENTS/implementation.md` for test file location.

STEP 2 — Run the test:
- cd framework/
- Run: envFile=.env.<target_env> npx playwright test <testName>.test --retries=0 --trace on
- IMPORTANT: Always use --retries=0 --trace on (retries disabled, traces always captured for debug agent)
- Capture stdout, stderr, exit code

STEP 3 — Write results IMMEDIATELY after test completes:
- Parse test results (pass/fail per test case)
- Locate trace files: find test-results/ -name "trace.zip"
- Include trace paths in per-error entries
- Write results to `memory/tickets/$ARGUMENTS/test-results.json`
- Update checkpoint: add "test-runner" to completed_stages
- If ALL PASS: set status to "passed" in test-results.json
- If ANY FAIL: set status to "failed" with failure details and trace paths

STEP 4 — Upload video (MANDATORY when all tests pass):
If ALL tests passed, upload the recorded video to S3:
    cd $E2E_FRAMEWORK_PATH
    VIDEO_URL=$(node $PROJECT_ROOT/scripts/upload-test-video.js "<testName>" "<env>" 2>/dev/null)
    # testName = the value from `let testName = "..."` in the test file
    # env = stg or dev (from triage.json or checkpoint)
If VIDEO_URL is non-empty, update test-results.json:
    python3 -c "
import json
with open('memory/tickets/$ARGUMENTS/test-results.json', 'r+') as f:
    data = json.load(f)
    data['video_url'] = '<VIDEO_URL>'
    f.seek(0); json.dump(data, f, indent=4); f.truncate()
"
If the upload fails, set video_url to null — do NOT block the pipeline.

PROGRESS REPORTING — after writing test-results.json (with video_url), run:
    ./scripts/report-to-dashboard.sh $ARGUMENTS test-runner

IMPLEMENTATION CONTEXT:
<paste implementation.md>
```

**Spawn debug teammate (opus) IN PARALLEL — do NOT wait for tester:**

```
You are the "developer" teammate for Jira ticket $ARGUMENTS.

YOUR TASK: Watch for test results, and if tests fail, debug and fix them. You run IN PARALLEL with the test-runner.

DO NOT read any agent .md files. All instructions are below.

————————————————————————————————————————————————————

STEP 1 — SKELETON OUTPUT (do this IMMEDIATELY — your VERY FIRST action):

    mkdir -p memory/tickets/$ARGUMENTS
    echo -e "\n## Debug Cycle 1 -- $(date -u +%Y-%m-%dT%H:%M:%SZ)\n**Status**: waiting for test results..." >> memory/tickets/$ARGUMENTS/debug-history.md
    python3 -c "
import json
data = {'total_cycles': 0, 'final_status': 'in_progress', 'cycles': []}
with open('memory/tickets/$ARGUMENTS/debug-output.json', 'w') as f:
    json.dump(data, f, indent=4)
"

————————————————————————————————————————————————————

CRITICAL OUTPUT RULE — UPDATE FILES AFTER EVERY ACTION:
  - After analyzing failures: append findings to debug-history.md
  - After each fix+commit: append cycle details to debug-history.md AND update debug-output.json with the cycle entry
  - After each re-run: overwrite test-results.json with new results AND update debug-output.json
  - Do NOT batch all writes to the end. Write incrementally so partial data exists even if you run out of turns.

————————————————————————————————————————————————————

STEP 2 — POLL FOR TEST RESULTS:

Poll every 15 seconds until test-results.json has final status:

    while true; do
        if [ -f memory/tickets/$ARGUMENTS/test-results.json ]; then
            STATUS=$(python3 -c "import json; d=json.load(open('memory/tickets/$ARGUMENTS/test-results.json')); print(d.get('status', ''))" 2>/dev/null)
            if [ "$STATUS" = "passed" ] || [ "$STATUS" = "failed" ]; then echo "STATUS: $STATUS"; break; fi
        fi
        echo "Waiting..."; sleep 15
    done

IF ALL PASS: Write "no debug needed" to debug-history.md, update checkpoint.json, and exit.
IF FAILURES: Continue to Step 3.

————————————————————————————————————————————————————

STEP 3 — ANALYZE FAILURES (max 3 cycles):

For each cycle:

A. ANALYZE TRACES FIRST — extract data from Playwright traces before anything else:

    cd $E2E_FRAMEWORK_PATH
    find test-results/ -name "trace.zip" 2>/dev/null
    # Extract and inspect:
    mkdir -p /tmp/trace-debug && unzip -o <trace-path> -d /tmp/trace-debug 2>/dev/null
    # Network log:
    cat /tmp/trace-debug/*.har 2>/dev/null | python3 -c "
    import json, sys
    har = json.load(sys.stdin)
    for entry in har['log']['entries'][-20:]:
        print(f\"{entry['response']['status']} {entry['request']['url'][:100]}\")
    " 2>/dev/null || true

B. IF TRACE IS INSUFFICIENT — use playwright-cli (NOT raw node scripts):

    playwright-cli open "$STAGING_URL"
    playwright-cli fill "input[name='email'],input[type='email']" "$STAGING_USER"
    playwright-cli fill "input[name='password'],input[type='password']" "$STAGING_PASSWORD"
    playwright-cli click "button[type='submit']"
    playwright-cli screenshot
    playwright-cli goto "<target-page-url>"
    playwright-cli snapshot
    playwright-cli screenshot

    NEVER use raw `node -e` with Playwright API. ALWAYS use playwright-cli commands.
    playwright-cli is already installed globally. Do NOT run npm install.

C. FIX CODE — edit selectors/actions/test files based on findings.

D. COMMIT FIX:

    cd $E2E_FRAMEWORK_PATH
    git add <fixed-files>
    git commit -m "OXDEV-<num>: fix <error_type> in <test_name> (debug cycle <N>)"

E. RE-RUN TEST (always --retries=0 --trace on):

    cd $E2E_FRAMEWORK_PATH && envFile=.env.stg npx playwright test <test-file> --retries=0 --trace on

F. EVALUATE:
   - All pass → upload video (step G), then write output files
   - Still failing and cycle < 3 → next cycle
   - Still failing and cycle = 3 → add ai-failed label:
     acli jira workitem edit --key "$ARGUMENTS" --labels "ai-failed" --yes

G. UPLOAD VIDEO (MANDATORY when all tests pass):
   If all tests passed (after any cycle or on first run), upload the video:

    cd $E2E_FRAMEWORK_PATH
    TEST_NAME=$(grep -oP 'let testName\s*=\s*"\K[^"]*' <test-file-path> 2>/dev/null)
    VIDEO_URL=$(node $PROJECT_ROOT/scripts/upload-test-video.js "$TEST_NAME" "stg" 2>/dev/null)
    if [ -n "$VIDEO_URL" ]; then
        python3 -c "
import json
with open('memory/tickets/$ARGUMENTS/test-results.json', 'r+') as f:
    data = json.load(f)
    data['video_url'] = '$VIDEO_URL'
    f.seek(0); json.dump(data, f, indent=4); f.truncate()
"
    fi

   If upload fails, set video_url to null — do NOT block the pipeline.

————————————————————————————————————————————————————

STEP 4 — WRITE OUTPUT FILES (MANDATORY — reserve last 3 turns):

1. Write memory/tickets/$ARGUMENTS/debug-output.json (structured JSON with cycles array)
2. Update memory/tickets/$ARGUMENTS/debug-history.md (append each cycle)
3. Update memory/tickets/$ARGUMENTS/test-results.json with latest results
4. Update memory/tickets/$ARGUMENTS/checkpoint.json:
   - If PASS: add "debug" to completed_stages, set current_stage to "pr"
   - If FAIL: add "debug" to completed_stages, set status to "failed"
5. Append audit entries to memory/tickets/$ARGUMENTS/audit.md

NEVER modify: setHooks.js, playwright.config.js, params/global.json
NEVER use page.waitForLoadState("networkidle") — use explicit waits instead

PROGRESS REPORTING — after each fix and after each re-run, update debug-history.md THEN run:
    ./scripts/report-to-dashboard.sh $ARGUMENTS debug --status cycle_<N>

IMPLEMENTATION CONTEXT:
<paste implementation.md>
```

Wait for **both** teammates to complete.

**DASHBOARD REPORT (MANDATORY — EXECUTE BEFORE PROCEEDING TO NEXT PHASE):**
```bash
./scripts/report-to-dashboard.sh $ARGUMENTS test-runner --status completed
```

**VERIFY OUTPUT (CRITICAL — agents often fail to write output files):**

Check each file exists and is non-empty. If missing, the lead writes a fallback DIRECTLY (do not re-spawn — re-spawning wastes turns and often fails too):

```bash
# 1. test-results.json — if missing, check if test-runner left results in the framework
if [ ! -s memory/tickets/$ARGUMENTS/test-results.json ]; then
    # Try to find results from the last test run
    cd $E2E_FRAMEWORK_PATH
    LAST_RESULT=$(find test-results/ -name "results.json" -newer memory/tickets/$ARGUMENTS/checkpoint.json 2>/dev/null | head -1)
    if [ -n "$LAST_RESULT" ]; then
        cp "$LAST_RESULT" memory/tickets/$ARGUMENTS/test-results.json
    else
        echo '{"status":"unknown","error":"Agent did not write test-results.json","total":0,"passed":0,"failed":0}' > memory/tickets/$ARGUMENTS/test-results.json
    fi
fi

# 2. debug-history.md — if missing or only has skeleton, write minimal entry
if [ ! -s memory/tickets/$ARGUMENTS/debug-history.md ] || ! grep -q "Debug Cycle" memory/tickets/$ARGUMENTS/debug-history.md 2>/dev/null; then
    echo -e "## Debug\n**Status**: Agent completed without writing debug history.\nCheck git log on the feature branch for any fixes applied." > memory/tickets/$ARGUMENTS/debug-history.md
fi

# 3. debug-output.json — if missing, write minimal JSON
if [ ! -s memory/tickets/$ARGUMENTS/debug-output.json ]; then
    echo '{"total_cycles":0,"final_status":"unknown","cycles":[]}' > memory/tickets/$ARGUMENTS/debug-output.json
fi
```

This ensures the pipeline always has output files to read, even when agents fail to write them.

**Result evaluation:**
- Read `test-results.json` for final status
- If PASSED:
  1. **Ensure video was uploaded** — check if `video_url` is set in test-results.json. If null/empty, the lead uploads it as a fallback:
     ```bash
     VIDEO_URL_CHECK=$(python3 -c "import json; d=json.load(open('memory/tickets/<TICKET-KEY>/test-results.json')); v=d.get('video_url',''); print('yes' if v and v != 'null' else 'no')" 2>/dev/null)
     if [ "$VIDEO_URL_CHECK" = "no" ]; then
         cd $E2E_FRAMEWORK_PATH
         TEST_NAME=$(grep -oP 'let testName\s*=\s*"\K[^"]*' <test-file-path> 2>/dev/null)
         VIDEO_URL=$(node $PROJECT_ROOT/scripts/upload-test-video.js "$TEST_NAME" "stg" 2>/dev/null)
         if [ -n "$VIDEO_URL" ]; then
             python3 -c "
     import json
     with open('memory/tickets/<TICKET-KEY>/test-results.json', 'r+') as f:
         data = json.load(f)
         data['video_url'] = '$VIDEO_URL'
         f.seek(0); json.dump(data, f, indent=4); f.truncate()
     "
         fi
     fi
     ```
  2. Report debug stage completed, proceed to Phase 7
- If FAILED: stop pipeline, add `ai-failed` label, report failure:
  ```bash
  acli jira workitem edit --key "$ARGUMENTS" --labels "ai-failed" --yes
  ```
- **DASHBOARD REPORT (MANDATORY — EXECUTE BEFORE PROCEEDING TO NEXT PHASE):**
  ```bash
  ./scripts/report-to-dashboard.sh $ARGUMENTS debug --status completed
  ```

**WATCH CHECK (if `--watch` flag is set):** Run `./scripts/watch-check.sh <TICKET-KEY>` and follow the decision matrix from the "Watch Check" section above before proceeding.

---

## Phase 6.5: Cross-Environment Validation

**DASHBOARD REPORT (MANDATORY — report BEFORE starting):**
```bash
./scripts/report-stage.sh $ARGUMENTS cross-env-check --status in_progress
```

Only run if test-results.json shows `status: "passed"`.

### Step 1: Check skip conditions

```bash
cd $E2E_FRAMEWORK_PATH
# Check for MongoDB baseline pattern
grep -l "findDoc\|replaceDoc\|updateCritical\|updateCriticalData" <test-file-path> 2>/dev/null
# Check for scan steps (triggerFullScanAndWait, triggerScan, runScan, scanTimeOut usage)
grep -l "triggerFullScanAndWait\|triggerScan\|runScan\|scanTimeOut" <test-file-path> 2>/dev/null
```

If **either** grep finds matches → skip cross-env check entirely. Baseline tests are inherently variable, and scan-heavy tests take ~45min per run making re-runs impractical. Proceed directly to Phase 7 (PR).

### Step 2: Run on 4 environments in parallel

Run the test on stg, prod, onprem1, and onprem2 simultaneously. Use `--output` to isolate artifacts per env:

```bash
cd $E2E_FRAMEWORK_PATH
mkdir -p /tmp/cross-env-$ARGUMENTS/{stg,prod,onprem1,onprem2}

envFile=.env.stg npx playwright test <test-file> --retries=0 --trace on \
  --output /tmp/cross-env-$ARGUMENTS/stg > /tmp/cross-env-$ARGUMENTS/stg/stdout.log 2>&1 &
PID_STG=$!

envFile=.env.prod npx playwright test <test-file> --retries=0 --trace on \
  --output /tmp/cross-env-$ARGUMENTS/prod > /tmp/cross-env-$ARGUMENTS/prod/stdout.log 2>&1 &
PID_PROD=$!

envFile=.env.onPrem1 npx playwright test <test-file> --retries=0 --trace on \
  --output /tmp/cross-env-$ARGUMENTS/onprem1 > /tmp/cross-env-$ARGUMENTS/onprem1/stdout.log 2>&1 &
PID_ONPREM1=$!

envFile=.env.onPrem2 npx playwright test <test-file> --retries=0 --trace on \
  --output /tmp/cross-env-$ARGUMENTS/onprem2 > /tmp/cross-env-$ARGUMENTS/onprem2/stdout.log 2>&1 &
PID_ONPREM2=$!

wait $PID_STG;     EXIT_STG=$?
wait $PID_PROD;    EXIT_PROD=$?
wait $PID_ONPREM1; EXIT_ONPREM1=$?
wait $PID_ONPREM2; EXIT_ONPREM2=$?
```

**CRITICAL — env file naming**: The `envFile` values use exact framework filenames: `.env.onPrem1` and `.env.onPrem2` (capital P). Do NOT lowercase them.

Read each env's `stdout.log` and parse pass/fail counts. Write initial results to `memory/tickets/$ARGUMENTS/cross-env-results.json`.

### Step 3: Evaluate results (tiered)

**Tier 1 — Required envs (stg + prod):**

Both stg AND prod MUST pass. If either fails:
1. Read the failure log and trace from `/tmp/cross-env-$ARGUMENTS/<failing-env>/`
2. Enter debug cycle (same pattern as Phase 5+6 — analyze trace, fix code, re-run)
3. After fixing, re-verify on BOTH stg and prod
4. Max 3 stalled debug cycles. If exhausted → `ai-failed` label, stop pipeline

**Tier 2 — Optional envs (onprem1 + onprem2):**

Only evaluate after stg+prod both pass. For each failing onprem env:
1. Read the failure log + trace from `/tmp/cross-env-$ARGUMENTS/<env>/`
2. Analyze root cause — common patterns:
   - **Feature not available on-prem**: selector not found, page element missing → add `test.skip(environment.includes("onPrem"), "feature not available on-prem")`
   - **Different data/org config**: assertion mismatch → add env-conditional logic using `if (environment === "onPrem1") { ... }` or `if (environment.includes("onPrem")) { ... }` (matching existing framework patterns)
   - **Different URLs/navigation**: → add env-conditional URL handling
3. Commit the adaptation
4. Re-run on the failing onprem env to verify the adaptation works
5. **REGRESSION CHECK (CRITICAL)**: Re-run on stg AND prod to ensure the adaptation didn't break them
6. If regression check fails → `git revert HEAD --no-edit`, proceed to PR without the adaptation, note the skipped env in MR description
7. Max **2** adaptation attempts per onprem env. If both fail, skip that env.

### Step 4: Post-evaluation

| Outcome | Action |
|---------|--------|
| **4/4 pass** | Proceed to PR. Note "Cross-env: 4/4 passed" in MR description |
| **stg+prod pass, onprem adapted** | Proceed to PR. Note adaptations in MR description |
| **stg+prod pass, onprem skipped** | Proceed to PR. Add `onprem-incompatible` label to Jira. Note in MR description which envs were skipped and why |
| **stg or prod fail after debug** | Add `ai-failed` label, stop pipeline |

```bash
# If onprem-incompatible:
acli jira workitem edit --key "$ARGUMENTS" --labels "onprem-incompatible" --yes
```

### Step 5: Write output and update checkpoint

Write `memory/tickets/$ARGUMENTS/cross-env-results.json`:
```json
{
    "envs": {
        "stg":     { "status": "passed", "exit_code": 0, "total": 5, "passed": 5, "failed": 0 },
        "prod":    { "status": "passed", "exit_code": 0, "total": 5, "passed": 5, "failed": 0 },
        "onprem1": { "status": "passed|adapted|skipped", "exit_code": 0, "adaptation": "description if adapted", "skip_reason": "reason if skipped" },
        "onprem2": { "status": "passed|adapted|skipped", "exit_code": 0 }
    },
    "required_envs": ["stg", "prod"],
    "optional_envs": ["onprem1", "onprem2"],
    "required_passed": true,
    "all_passed": false,
    "adaptations_made": [
        { "env": "onprem1", "type": "test_skip|conditional_logic", "test": "#N test name", "reason": "...", "commit": "sha" }
    ]
}
```

Update `checkpoint.json`: add `"cross-env-check"` to `completed_stages`, set `current_stage: "pr"`.

**DASHBOARD REPORT (MANDATORY — EXECUTE BEFORE PROCEEDING TO NEXT PHASE):**
```bash
./scripts/report-to-dashboard.sh $ARGUMENTS cross-env-check --status completed
```

---

## Phase 7: PR (Spawn pr teammate if tests passed)

**DASHBOARD REPORT (MANDATORY — report BEFORE spawning agent):**
```bash
./scripts/report-stage.sh $ARGUMENTS pr --status in_progress
```

Only proceed here if test-results.json shows `status: "passed"`.

The lead creates the MR directly (simple operation):

1. **Fetch latest developmentV2** before creating MR (ensures no conflicts):
   ```bash
   cd $E2E_FRAMEWORK_PATH && git fetch origin developmentV2
   ```
2. Verify branch is pushed and up to date
3. Create GitLab MR via `glab`:
   ```bash
   glab mr create \
     --source-branch "test/$ARGUMENTS-<slug>" \
     --target-branch "developmentV2" \
     --title "test(<feature_area>): $ARGUMENTS - <summary>" \
     --description "$(cat templates/pr-description.md | sed 's/<TICKET-KEY>/$ARGUMENTS/g')"
   ```
3. Add MR link as Jira comment on the ticket
4. Write to `memory/tickets/$ARGUMENTS/pr-result.md`
5. Update checkpoint: add "pr" to completed_stages
6. **DASHBOARD REPORT (MANDATORY — EXECUTE BEFORE PROCEEDING TO NEXT PHASE):**
   ```bash
   ./scripts/report-to-dashboard.sh $ARGUMENTS pr
   ```

---

## Phase 7.5: Retrospective (Spawn retrospective teammate)

**DASHBOARD REPORT (MANDATORY — report BEFORE spawning agent):**
```bash
./scripts/report-stage.sh $ARGUMENTS retrospective --status in_progress
```

Spawn retrospective teammate (haiku):

```
You are the "retrospective" teammate for Jira ticket $ARGUMENTS.

YOUR TASK: Extract learnings from this pipeline run and update shared memory.

INSTRUCTIONS:
1. Read `.claude/agents/retrospective-agent.md` for instructions.
2. Read `memory/tickets/$ARGUMENTS/debug-history.md`
3. Read `memory/tickets/$ARGUMENTS/validation-report.json`
4. Read `memory/tickets/$ARGUMENTS/implementation.md`
5. Read `memory/tickets/$ARGUMENTS/triage.json`
6. Append learnings to `memory/selector-patterns.md`, `memory/test-patterns.md`, and `memory/agents/*.md`
7. Mark checkpoint as retro'd.
```

Wait for retrospective to complete. This is non-blocking — if it fails, log warning and continue to finalize.

---

## Phase 8: Finalize

After PR creation:

1. Present final summary to the user:
   ```
   Pipeline complete for $ARGUMENTS!
   - Feature area: <feature_area>
   - Test type: <test_type>
   - Complexity: <complexity>
   - Debug cycles: <count>

   | Artifact | Location |
   |----------|----------|
   | Test file | framework/tests/UI/<feature_area>/<testName>.test.js |
   | Actions | framework/actions/<feature_area>.js |
   | Selectors | framework/selectors/<feature_area>.json |
   | MR | <MR-URL> |
   ```
2. Add final Jira comment on the ticket:
   ```
   **[QA Agent: pipeline-lead]** <timestamp>

   E2E test pipeline completed successfully.
   - Stages: triage > explorer > playwright > code-writer > test-runner > pr
   - Test file: <path>
   - MR: <MR-URL>
   - Debug cycles: <count>
   ```
3. Update labels:
   ```bash
   acli jira workitem edit --key "$ARGUMENTS" --remove-labels "ai-in-progress" --yes
   acli jira workitem edit --key "$ARGUMENTS" --labels "ai-done" --yes
   ```
4. Update checkpoint: `status: "completed"`
5. **DASHBOARD REPORT (MANDATORY — report finalize THEN review-pr):**
   ```bash
   ./scripts/report-to-dashboard.sh $ARGUMENTS finalize --status completed
   ./scripts/report-to-dashboard.sh $ARGUMENTS review-pr --status completed
   ```
   The `review-pr` stage is the final pipeline stage — it signals the MR is ready for human review. Must be reported with `--status completed` so the dashboard marks the pipeline as "Passed".
6. Clean up browser session data:
   ```bash
   node .claude/skills/chrome-cdp/scripts/cdp.mjs stop 2>/dev/null || rm -rf .playwright-cli/ 2>/dev/null || true
   ```
7. **Stop relay daemon**:
   ```bash
   if [ -f "memory/tickets/$ARGUMENTS/relay.pid" ]; then
       kill $(cat "memory/tickets/$ARGUMENTS/relay.pid") 2>/dev/null || true
       rm -f "memory/tickets/$ARGUMENTS/relay.pid"
   fi
   ```
8. Clean up the agent team (shutdown all teammates, delete team)

---

## Error Handling

- If any teammate fails: read checkpoint error, log to audit, update Jira with `ai-failed` label and failure comment:
  ```bash
  acli jira workitem edit --key "$ARGUMENTS" --labels "ai-failed" --yes
  ```
- On failure, write checkpoint with error details:
  ```json
  {
    "status": "failed",
    "error": "<error description>",
    "failed_stage": "<stage name>"
  }
  ```
- **DASHBOARD REPORT (MANDATORY)** — execute on failure:
  ```bash
  ./scripts/report-to-dashboard.sh $ARGUMENTS <stage> --status failed
  ```
- If a teammate stops unexpectedly: spawn a replacement to continue from checkpoint
- On debug loop exhaustion (3 cycles): add `ai-failed` label, leave detailed comment with all debug attempts:
  ```bash
  acli jira workitem edit --key "$ARGUMENTS" --labels "ai-failed" --yes
  ```
- **Always clean up browser session data on exit** (success or failure):
  ```bash
  node .claude/skills/chrome-cdp/scripts/cdp.mjs stop 2>/dev/null || rm -rf .playwright-cli/ 2>/dev/null || true
  ```

## Team Structure

- Team name: `qa-e2e-$ARGUMENTS`
- Teammates:
  - `analyst` (sonnet) -- framework exploration
  - `browser` (sonnet) -- Playwright locator gathering
  - `developer` (opus) -- test implementation and debug fixes
  - `tester` (sonnet) -- test execution and result parsing
  - `validator` (haiku) -- output validation and quality checklist
  - `retrospective` (haiku) -- cross-ticket learning extraction

## Shared Memory

- All agents share `memory/tickets/$ARGUMENTS/` for per-ticket context
- `exploration.md` flows from analyst to developer (framework patterns)
- `playwright-data.json` flows from browser to developer (locators)
- `implementation.md` flows from developer to tester (test file info)
- `test-results.json` flows from tester back to developer (debug loop)
- `debug-history.md` persists across debug cycles
- After pipeline completion, agents update:
  - `memory/test-patterns.md` with discovered patterns
  - `memory/selector-patterns.md` with selector discoveries
  - Agent-specific memory files in `memory/agents/`

## Arguments

- `$ARGUMENTS` -- the Jira ticket key, optionally followed by flags (e.g., `OXDEV-123` or `OXDEV-123 --auto --watch`)
- `--auto` -- skip plan approval, run fully unattended
- `--watch` -- re-check Jira ticket between phases, re-triage on description changes, abort on ticket closure

## Jira Updates

Throughout the pipeline, leave comments on the ticket at each major milestone:
```
**[QA Agent: <agent-name>]** <timestamp>

<stage summary with key findings>
```

This ensures stakeholders can track progress in real time by watching the Jira ticket.
