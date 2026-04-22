---
name: qa-discover-changes
description: Discover testable changes from GitLab merged MRs in monitored OX Security services. Scans for changes, analyzes diffs, and creates detailed Jira tickets with step-by-step QA instructions. Optionally triggers the E2E test pipeline for each created ticket.
disable-model-invocation: true
argument-hint: "[service-name] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--no-auto] [--ticket OXDEV-NNN] [--type bug|rfe|task|sprint] [--prompt \"free text description\"]"
---

# Discovery Pipeline: Auto-detect Changes & Create E2E Test Tickets

Scan GitLab for merged MRs in monitored services, analyze the diffs, and create Jira tickets with detailed QA instructions for E2E test creation. Can also accept a specific Jira ticket as input instead of scanning GitLab.

## Usage

```
/qa-discover-changes
/qa-discover-changes frontend
/qa-discover-changes --since 2026-03-01 --until 2026-03-13
/qa-discover-changes frontend connectors --since 2026-03-01 --no-auto
/qa-discover-changes --ticket OXDEV-12345 --type rfe
/qa-discover-changes --ticket OXDEV-12345 --type bug --no-auto
/qa-discover-changes --ticket OXDEV-12345 --type sprint
/qa-discover-changes --prompt "Test the new severity filter on Issues page - verify Critical/High/Medium/Low options"
/qa-discover-changes --prompt "Verify RBAC role switching works for admin and viewer roles" --no-auto
```

## Flags

Parse `$ARGUMENTS` for optional parameters:
- **Service names** (positional): Filter to specific services. Valid: `frontend`, `connectors`, `settings-service`, `report-service`, `gateway`. If omitted, scan all services.
- **`--since YYYY-MM-DD`**: Override scan start date (default: last scan timestamp per service, or 7 days ago for first run).
- **`--until YYYY-MM-DD`**: Override scan end date (default: now).
- **`--no-auto`**: Only create Jira tickets — do NOT trigger the E2E test pipeline for created tickets.
- **`--ticket OXDEV-NNN`**: Skip GitLab scanning entirely. Read the provided Jira ticket, pass it to the Analyzer to create testable scenarios, then create a QA E2E test ticket. Incompatible with service names, `--since`, and `--until`. **Requires `--type`.**
- **`--type bug|rfe|task|sprint`**: Discovery type (required with `--ticket`). Determines the scan ID prefix. Valid values: `bug`, `rfe`, `task`, `sprint`.
- **`--prompt "free text"`**: Skip both GitLab scanning and Jira ticket reading. Use the provided free-text description as the source for the Analyzer to create testable scenarios. Incompatible with `--ticket`, service names, `--since`, `--until`. The text describes what to test — feature area, user flows, expected behavior.
- **`--scan-id ID`**: Override the auto-generated scan ID. Used by the worker daemon to pass dashboard-originated pipeline keys. If not provided, generates scan ID automatically (see below).

---

## Before Starting — Generate Scan ID

1. Check if `--scan-id` was provided in `$ARGUMENTS`:
   - If yes → use that value as the scan ID directly (do NOT append date suffixes).
   - If no → generate scan ID based on mode:
     - **Ticket mode** (`--ticket OXDEV-NNN --type <type>`):
       - Format: `<TYPE>-<TICKET-KEY>-DIS` (type is uppercased)
       - Examples: `RFE-OXDEV-12345-DIS`, `BUG-OXDEV-456-DIS`, `TASK-OXDEV-789-DIS`, `SPRINT-OXDEV-100-DIS`
       - If `--type` is not provided with `--ticket`, **ask the user** which type to use (bug, rfe, task, sprint). Do NOT default silently.
     - **Prompt mode** (`--prompt "text"`):
       - Format: `PROMPT-DIS-<YYYY-MM-DD-HHmm>` (date with minutes for uniqueness)
       - Example: `PROMPT-DIS-2026-03-24-1430`
       - Generate via: `date -u +%Y-%m-%d-%H%M`
     - **Scan mode** (no `--ticket`, no `--prompt`):
       - Format: `PR-toSTG-<YYYY-MM-DD>` (e.g., `PR-toSTG-2026-03-20`)
       - If a scan with the same date already exists, append a letter suffix: `PR-toSTG-2026-03-20b`, `PR-toSTG-2026-03-20c`, etc.
2. Record the scan ID in `memory/discovery/last-scan.json`.
3. Create directory: `memory/discovery/scans/<SCAN-ID>/`.
4. Initialize audit log: `memory/discovery/scans/<SCAN-ID>/audit.md`.

---

## Mode Detection

Check `$ARGUMENTS` for mode flags (mutually exclusive):
- If `--prompt "text"` → execute **Phase 1-P (Prompt-Based Input)**, then skip to Phase 2.
- If `--ticket OXDEV-NNN` → execute **Phase 1-T (Ticket-Based Input)**, then skip to Phase 2.
- Otherwise → execute **Phase 1 (Scanner)** as normal.

---

## Phase 1-P: Prompt-Based Input (when `--prompt` is provided)

Instead of scanning GitLab or reading a Jira ticket, use the free-text prompt as the source for the Analyzer.

### 1p-1. Validate arguments

If `--prompt` is combined with `--ticket`, service names, `--since`, or `--until`, inform the user these flags are ignored in prompt mode.

### 1p-2. Parse the prompt text

Extract the quoted text after `--prompt`. The text describes what to test — it may include:
- Feature area (e.g., "Issues page", "RBAC", "dashboard filters")
- User flows to test (e.g., "login, switch org, navigate to settings")
- Expected behavior (e.g., "dropdown should show severity options")
- Specific elements to verify

### 1p-3. Cross-reference with existing E2E tests

Use the prompt text to infer the feature area, then check existing tests:
```bash
ls $E2E_FRAMEWORK_PATH/tests/UI/<inferred-feature-area>/ 2>/dev/null
```

### 1p-4. Build scanner-output.json

Construct `memory/discovery/scans/<SCAN-ID>/scanner-output.json` with the prompt as the source:

```json
{
    "scan_id": "<SCAN-ID>",
    "mode": "prompt",
    "source_prompt": "<the full prompt text>",
    "services_scanned": [],
    "total_mrs": 0,
    "all_mrs": [],
    "jira_tickets": {},
    "status": "completed"
}
```

The Analyzer agent (Phase 2) will use `source_prompt` to create testable scenarios — similar to how it uses ticket descriptions in ticket mode, but without any MR diffs or Jira context.

### 1p-5. Report to dashboard

```bash
./scripts/report-to-dashboard.sh <SCAN-ID> scanner --status completed
```

Then proceed to Phase 2 (Analyzer).

---

## Phase 1-T: Ticket-Based Input (when `--ticket` is provided)

Instead of scanning GitLab, read the provided Jira ticket and construct a scanner-output.json for the Analyzer.

### 1t-1. Validate arguments

If `--ticket` is combined with service names, `--since`, or `--until`, inform the user these flags are ignored in ticket mode.

### 1t-2. Read the Jira ticket

```bash
acli jira workitem view <TICKET-KEY> --fields "key,summary,description,labels,status,issuetype,priority" --json
```

Parse the response to extract: key, summary, description, labels, status, issue type, priority.

If the ticket is not found or not in OXDEV project, stop with an error.

### 1t-3. Extract MR references from the ticket

Search the ticket description and summary for GitLab MR references:
- URLs matching `gitlab.com/.*/merge_requests/\d+`
- Text patterns like `!NNN` (MR shorthand)
- Branch names matching `feat/OXDEV-*`, `fix/OXDEV-*`, etc.

Also search for the ticket key in GitLab MRs across monitored services:
```bash
./scripts/gitlab-retry.sh "/projects/<project_id>/merge_requests?search=<TICKET-KEY>&state=merged&per_page=20"
```

Run this for each monitored service (frontend, connectors, settings-service, report-service). Use sequential calls.

### 1t-4. Fetch MR diffs (if MRs found)

For each MR found, fetch its diff details:
```bash
./scripts/gitlab-retry.sh "/projects/<project_id>/merge_requests/<iid>/changes"
```

Extract: iid, title, author, merged_at, web_url, target_branch, source_branch, description, labels, changed_files, diff_summary, inferred_feature_area.

### 1t-5. Build scanner-output.json

Construct `memory/discovery/scans/<SCAN-ID>/scanner-output.json` in the same format the Analyzer expects:

```json
{
    "scan_id": "<SCAN-ID>",
    "mode": "ticket",
    "source_ticket": "<TICKET-KEY>",
    "services_scanned": ["<services where MRs were found>"],
    "total_mrs": <N>,
    "results_by_service": {},
    "all_mrs": [
        {
            "iid": <iid>,
            "title": "<MR title>",
            "author": "<author>",
            "merged_at": "<timestamp>",
            "web_url": "<url>",
            "target_branch": "<branch>",
            "source_branch": "<branch>",
            "description": "<description>",
            "labels": [],
            "inferred_feature_area": "<area>",
            "changed_files": [{"path": "<path>", "additions": <N>, "deletions": <N>}],
            "diff_summary": "<summary>",
            "jira_refs": ["<TICKET-KEY>"],
            "jira_ref_sources": {"<TICKET-KEY>": ["provided"]},
            "is_mega_merge": false
        }
    ],
    "jira_tickets": {
        "<TICKET-KEY>": {
            "key": "<TICKET-KEY>",
            "summary": "<ticket summary>",
            "description": "<ticket description>",
            "status": "<status>",
            "priority": "<priority>",
            "labels": ["<labels>"],
            "issue_type": "<type>"
        }
    },
    "status": "completed"
}
```

**If NO MRs were found** for the ticket in any service, still build the scanner-output.json but with an empty `all_mrs` array. The Analyzer will use the Jira ticket description alone to create scenarios.

### 1t-6. Dashboard report and continue

```bash
./scripts/report-to-dashboard.sh <SCAN-ID> scanner --status completed
```

Skip Phase 1d (Jira enrichment) — the ticket data is already in the scanner-output.json. Continue directly to Phase 2 (Analyzer).

---

## Phase 1: Scanner (Parallel team — one agent per service)

Create team `qa-scanner-<SCAN-ID>` and spawn one scanner agent per service in parallel.

### 1a. Prepare scan parameters

1. Read `memory/discovery/last-scan.json` for per-service timestamps and project IDs.
2. Parse `$ARGUMENTS` to determine which services to scan and date range overrides.
3. Determine scan range per service:
   - If `--since` provided: use that date
   - Else if `last_scanned_at` exists for service: use that timestamp
   - Else: use 7 days ago (default for first run)
   - If `--until` provided: use that date, else use now

### 1b. Spawn parallel scanner agents

Create team `qa-scanner-<SCAN-ID>`.

For **each** service to scan, spawn a `scanner-<service>` teammate (Haiku, max 10 turns) with this prompt:

```
You are the "scanner-<service>" teammate for discovery scan <SCAN-ID>.

MANDATORY OUTPUT — THIS IS YOUR #1 PRIORITY:
You MUST write `memory/discovery/scans/<SCAN-ID>/scanner-<service>.json` before finishing.
Your VERY FIRST action must be writing a skeleton output file (even with empty mrs_found array).
Then UPDATE it as you process each MR. If you run out of turns without this file, the pipeline is BLOCKED.

YOUR TASK: Scan the <service> GitLab project for merged MRs and fetch their diffs.

SERVICE DETAILS:
- Service: <service>
- Project ID: <project_id>
- Target branch: <target_branch>
- Scan range: <since> to <until>
- Scan ID: <SCAN-ID>

INSTRUCTIONS:
1. Write skeleton `memory/discovery/scans/<SCAN-ID>/scanner-<service>.json` NOW (before anything else).
2. Read `.claude/agents/scanner-agent.md` for detailed scanning instructions and output schema.
3. Use `./scripts/gitlab-retry.sh` for ALL GitLab API calls — NEVER use raw `glab api`.
4. Write results to `memory/discovery/scans/<SCAN-ID>/scanner-<service>.json`.

JIRA REFERENCE EXTRACTION:
For each MR, extract OXDEV ticket keys:
- Parse title, source_branch, and description with regex OXDEV-\d+
- Add jira_refs (array of unique keys) and jira_ref_sources (map of key -> [sources]) to each MR
- For mega-merge MRs (title matches "Development", "dev to main", "development into main"):
  - Set is_mega_merge: true
  - Fetch commits: ./scripts/gitlab-retry.sh "/projects/<project_id>/merge_requests/<iid>/commits?per_page=100"
  - Extract OXDEV keys from commit titles/messages, add to jira_refs with source "commit"
- For non-mega-merge MRs: set is_mega_merge: false

RULES:
- Read-only GitLab operations — never modify MRs
- Only scan the ONE service assigned to you (<service>)
- Use `./scripts/gitlab-retry.sh` for ALL GitLab API calls (provides 1s spacing + retry on 429/5xx)
- Write output incrementally — update the JSON after each MR is processed
```

**Spawn ALL service agents in parallel** — do NOT wait for one to finish before spawning the next. Each agent writes to its own file (`scanner-<service>.json`) so there are no conflicts.

### 1c. Merge results

After all scanner agents complete:

1. **Verify outputs**: Check that each `scanner-<service>.json` exists. For any missing files, write a fallback directly (do not re-spawn):
   ```json
   {"service":"<service>","project_id":<id>,"scan_id":"<SCAN-ID>","mrs_found":[],"total_mrs":0,"filtered_out":0,"status":"fallback","note":"Scanner agent completed without writing output."}
   ```

2. **Merge per-service JSONs** into `scanner-output.json`:
   ```bash
   python3 -c "
   import json, glob, os
   scan_dir = 'memory/discovery/scans/<SCAN-ID>'
   files = sorted(glob.glob(os.path.join(scan_dir, 'scanner-*.json')))
   services = [json.load(open(f)) for f in files if not f.endswith('scanner-output.json')]
   merged = {
       'scan_id': '<SCAN-ID>',
       'services_scanned': [s['service'] for s in services],
       'total_mrs': sum(s.get('total_mrs', len(s.get('mrs_found', []))) for s in services),
       'results_by_service': {s['service']: s for s in services},
       'all_mrs': [mr for s in services for mr in s.get('mrs_found', [])],
       'status': 'completed'
   }
   with open(os.path.join(scan_dir, 'scanner-output.json'), 'w') as f:
       json.dump(merged, f, indent=2)
   print(f'Merged {len(services)} service files, {merged[\"total_mrs\"]} total MRs')
   "
   ```

3. **Update `memory/discovery/last-scan.json`** with new timestamps per scanned service.
4. Append audit entries to `memory/discovery/scans/<SCAN-ID>/audit.md`.
5. **DASHBOARD REPORT (MANDATORY):**
   ```bash
   ./scripts/report-to-dashboard.sh <SCAN-ID> scanner --status completed
   ```

**If no MRs found across all services**: Report to dashboard, inform user "No new merged MRs found since last scan", and stop.

---

## Phase 1d: Jira Ticket Enrichment (Lead performs directly)

After merging scanner outputs, enrich the merged `scanner-output.json` with Jira ticket details for every OXDEV key referenced by the scanned MRs. This runs in the lead — the scanner agents do NOT access Jira.

**CRITICAL: ALL `acli` commands MUST run sequentially — NEVER run multiple `acli` calls in parallel.**

### 1d-1. Collect unique OXDEV keys

```python
python3 -c "
import json
with open('memory/discovery/scans/<SCAN-ID>/scanner-output.json') as f:
    data = json.load(f)
keys = set()
for mr in data.get('all_mrs', []):
    for ref in mr.get('jira_refs', []):
        keys.add(ref)
print('\n'.join(sorted(keys)))
print(f'Total unique tickets: {len(keys)}')
"
```

### 1d-2. Fetch ticket details (sequential acli calls)

For each unique OXDEV key, fetch ticket details:
```bash
acli jira workitem view OXDEV-NNN --fields "key,summary,description,labels,status,issuetype,priority" --json
```

If `acli` fails for a ticket (not found, permission denied), log the error and set `"ticket_not_found"` status for that key. Do not block the pipeline.

### 1d-3. Build jira_tickets map and compute alignment

Build a `jira_tickets` map and for each MR compute a preliminary `jira_alignment`:

```python
python3 -c "
import json, re

with open('memory/discovery/scans/<SCAN-ID>/scanner-output.json') as f:
    data = json.load(f)

# jira_tickets map populated from acli results (lead fills this in)
jira_tickets = {}  # { 'OXDEV-NNN': { key, summary, description, status, priority, labels, issue_type } }

# For each MR, compute alignment
for mr in data.get('all_mrs', []):
    refs = mr.get('jira_refs', [])
    if not refs:
        mr['jira_alignment'] = 'no_ticket'
        mr['jira_alignment_notes'] = 'No OXDEV ticket referenced in this MR'
        continue

    notes = []
    has_mismatch = False
    for ref in refs:
        ticket = jira_tickets.get(ref)
        if not ticket:
            notes.append(f'{ref}: ticket not found in Jira')
            continue
        # Extract keywords from ticket summary
        summary_words = set(re.findall(r'[a-zA-Z]{3,}', ticket.get('summary', '').lower()))
        # Check against changed file paths
        file_paths = ' '.join(f.get('path', '') for f in mr.get('changed_files', [])).lower()
        diff_text = mr.get('diff_summary', '').lower()
        matched = summary_words & set(re.findall(r'[a-zA-Z]{3,}', file_paths + ' ' + diff_text))
        if len(matched) < len(summary_words) * 0.3:
            notes.append(f'{ref}: possible scope mismatch — ticket mentions {summary_words - matched} not found in changed files')
            has_mismatch = True
        else:
            notes.append(f'{ref}: aligned — keywords {matched} found in diff')

    mr['jira_alignment'] = 'partial_mismatch' if has_mismatch else 'aligned'
    mr['jira_alignment_notes'] = '; '.join(notes)

data['jira_tickets'] = jira_tickets
with open('memory/discovery/scans/<SCAN-ID>/scanner-output.json', 'w') as f:
    json.dump(data, f, indent=2)
print(f'Enriched {len(jira_tickets)} tickets, {len(data.get(\"all_mrs\", []))} MRs')
"
```

**Important**: The Python snippet above is a template. The lead MUST:
1. Run `acli` for each unique OXDEV key first
2. Parse the JSON output from each `acli` call
3. Build the `jira_tickets` dict
4. Then run the alignment computation

### 1d-4. Audit and continue

Append audit entries for each Jira ticket fetched. Then continue to Phase 2.

If no OXDEV keys were found in any MRs, skip this phase silently (some repos may not follow the OXDEV convention).

---

## Phase 2: Analyzer (Spawn analyst teammate)

Create team `qa-discovery-<SCAN-ID>` (e.g., `qa-discovery-PR-toSTG-2026-03-20`).

Spawn analyst teammate (sonnet):

```
You are the "analyst" teammate for discovery scan <SCAN-ID>.

MANDATORY OUTPUT — THIS IS YOUR #1 PRIORITY:
You MUST write `memory/discovery/scans/<SCAN-ID>/analyzer-output.json` before finishing.
Your VERY FIRST action must be writing a skeleton analyzer-output.json (even with placeholder text).
Then UPDATE it as you analyze each MR. If you run out of turns without this file, the pipeline is BLOCKED.

YOUR TASK: Analyze the scanner output (MRs and/or Jira ticket data), classify changes, and group them into testable scenarios.

INSTRUCTIONS:
1. Write skeleton `memory/discovery/scans/<SCAN-ID>/analyzer-output.json` NOW (before anything else).
2. Read `.claude/agents/analyzer-agent.md` for detailed analysis instructions.
3. Read `memory/discovery/scans/<SCAN-ID>/scanner-output.json` for MR list and Jira ticket data.
4. Read `memory/framework-catalog.md` for framework overview.

TICKET MODE:
If scanner-output.json contains `"mode": "ticket"`, this is a ticket-based discovery (no GitLab scan).
The `source_ticket` field identifies the input ticket. The `jira_tickets` map contains its full details.
- If `all_mrs` is non-empty: analyze MRs as normal, using ticket description for additional context.
- If `all_mrs` is empty: create scenarios purely from the Jira ticket description and acceptance criteria.
  In this mode, infer the feature area from the ticket summary/description, write QA steps based on
  what the ticket describes, and mark `source_mrs: []` in the scenario. The ticket description is
  your primary source of truth for what to test.

ANALYSIS:
- For each MR, fetch diff via: glab api "/projects/<project_id>/merge_requests/<iid>/changes"
- Classify: frontend-ui, frontend-api, backend-api, backend-only (skip), config-ci (skip)
- Map changed files to app pages
- Cross-reference with existing E2E tests in $E2E_FRAMEWORK_PATH/tests/UI/
- Group related MRs into testable scenarios
- Write QA steps and elements for each scenario
- Assign priority: high (new, no coverage), medium (enhancement, partial), low (minor, covered)
- UPDATE analyzer-output.json after EACH scenario is created

JIRA CONTEXT:
The scanner output now includes enriched Jira data:
- jira_tickets: map of OXDEV-NNN -> {key, summary, description, status, priority, labels, issue_type}
- Per-MR jira_refs: array of OXDEV keys extracted from MR title/branch/description/commits
- Per-MR jira_alignment: preliminary alignment assessment ("aligned", "partial_mismatch", "no_ticket")
- Per-MR jira_alignment_notes: details of any mismatches

USE THIS DATA TO:
1. Validate that MR changes match what the linked Jira ticket describes (semantic validation)
2. Extract acceptance criteria from Jira ticket descriptions to enrich QA steps
3. Flag discrepancies where ticket scope doesn't match code changes
4. Add jira_context to each scenario: linked_tickets, ticket_summaries, alignment, discrepancies, acceptance_criteria_from_ticket
5. If lead flagged partial_mismatch, investigate deeper with your semantic understanding of the diff

PROGRESS REPORTING — after each major finding, update analyzer-output.json THEN run:
    ./scripts/report-to-dashboard.sh <SCAN-ID> analyzer

SCANNER OUTPUT:
<paste full scanner-output.json content here>
```

Wait for analyst to complete.

**VERIFY OUTPUT (CRITICAL — agents often fail to write output files):**

If `memory/discovery/scans/<SCAN-ID>/analyzer-output.json` is missing or empty, write a fallback DIRECTLY (do not re-spawn):
```bash
if [ ! -s memory/discovery/scans/<SCAN-ID>/analyzer-output.json ]; then
    echo '{"scan_id":"<SCAN-ID>","scenarios":[],"skipped_mrs":[],"status":"fallback","note":"Analyzer agent completed without writing output."}' > memory/discovery/scans/<SCAN-ID>/analyzer-output.json
fi
```

**DASHBOARD REPORT (MANDATORY):**
```bash
./scripts/report-to-dashboard.sh <SCAN-ID> analyzer --status completed
```

**If no testable scenarios found**: Report to dashboard, inform user "No testable scenarios identified from the scanned MRs", and stop.

---

## Phase 3: Ticket Creator (Lead performs directly)

The lead creates Jira tickets directly — this involves structured Jira operations using `acli`.

**CRITICAL: ALL `acli` commands MUST run sequentially — NEVER run multiple `acli` calls in parallel.** `acli` uses a shared auth state that breaks under concurrent access, causing all parallel calls to fail with cancellation errors. Process each scenario fully (search → create → label → comment) before moving to the next one.

1. Read `memory/discovery/scans/<SCAN-ID>/analyzer-output.json` for scenarios.
2. Read `templates/discovery-ticket.md` for ticket body template.
3. For each scenario **(ONE AT A TIME, sequentially)**:
   a. **Deduplicate**: Search Jira for existing tickets:
      ```bash
      acli jira workitem search --jql 'project = OXDEV AND labels = "e2e-test" AND summary ~ "<feature_keyword>" AND status != Done' --fields "key,summary,status"
      ```
   b. If duplicate found: log and skip.
   c. **Create ticket**:
      ```bash
      acli jira workitem create --project "OXDEV" --type "Task" --summary "E2E: <title>" --description "<body>"
      ```
   d. **Add labels**:
      ```bash
      acli jira workitem edit --key "<NEW-KEY>" --labels "ai-ready" "e2e-test" "auto-discovered" "<feature-area>" --yes
      ```
   e. **Add comment**:
      ```bash
      acli jira workitem comment create --key "<NEW-KEY>" --body "**[OX E2E Agent: ticket-creator]** <timestamp>

      Auto-discovered from GitLab MR scan (<SCAN-ID>).
      Source MRs: <list>
      Priority: <priority> | Complexity: <complexity>"
      ```
   f. Update `tickets-created.json` after each ticket.
4. Write final `memory/discovery/scans/<SCAN-ID>/tickets-created.json`.
5. Append audit entries.
6. **DASHBOARD REPORT (MANDATORY):**
   ```bash
   ./scripts/report-to-dashboard.sh <SCAN-ID> ticket-creator --status completed
   ```

---

## Phase 4: Pipeline Trigger (Optional)

If `--no-auto` was NOT set and tickets were created:

1. Present created tickets to the user:
   ```
   Discovery complete! Created N Jira tickets:

   | Key | Title | Priority | Feature |
   |-----|-------|----------|---------|
   | OXDEV-5678 | E2E: Verify filter dropdown on Issues | high | issues |
   | OXDEV-5679 | E2E: Test connector status badges | medium | connectors |

   Would you like to trigger the E2E test pipeline for these tickets?
   ```

2. If user confirms (or `--auto` was passed from parent pipeline):
   - For each created ticket, invoke: `/qa-autonomous-e2e <TICKET-KEY> --auto`
   - This chains the discovery pipeline into the existing implementation pipeline

---

## Phase 5: Finalize

1. Present final summary:
   ```
   Discovery Pipeline Complete (<SCAN-ID>)

   | Metric | Count |
   |--------|-------|
   | Services scanned | N |
   | MRs found | N |
   | Scenarios identified | N |
   | Tickets created | N |
   | Duplicates skipped | N |

   Created tickets: OXDEV-5678, OXDEV-5679
   ```

2. **DASHBOARD REPORT (MANDATORY):**
   ```bash
   ./scripts/report-to-dashboard.sh <SCAN-ID> ticket-creator --status completed
   ```

3. Clean up team if created.

---

## Error Handling

- If GitLab API fails: log error, skip that service, continue with others
- If Jira ticket creation fails: log error, skip that scenario, continue with others
- If analyzer agent fails: write fallback output, proceed with ticket creation using scanner data only
- On any failure, ensure `tickets-created.json` is written with partial results
- Never block on dashboard reporting errors

## Team Structure

### Scanner Team
- Team name: `qa-scanner-<SCAN-ID>`
- Teammates: one per service being scanned (only spawn agents for services matching the service filter argument)
  - `scanner-frontend` (haiku) — Scan frontend GitLab project for merged MRs
  - `scanner-connectors` (haiku) — Scan connectors GitLab project for merged MRs
  - `scanner-settings-service` (haiku) — Scan settings-service GitLab project for merged MRs
  - `scanner-report-service` (haiku) — Scan report-service GitLab project for merged MRs
  - `scanner-gateway` (haiku) — Scan gateway GitLab project for merged MRs

### Analyzer Team
- Team name: `qa-discovery-<SCAN-ID>`
- Teammates:
  - `analyst` (sonnet) — MR diff analysis and scenario creation

## Arguments

- `$ARGUMENTS` — optional service names, `--since`, `--until`, `--no-auto`, `--ticket`
- Service names: `frontend`, `connectors`, `settings-service`, `report-service`, `gateway`
- `--since YYYY-MM-DD` — scan start date override
- `--until YYYY-MM-DD` — scan end date override
- `--no-auto` — skip pipeline trigger, only create tickets
- `--ticket OXDEV-NNN` — skip GitLab scanning, use provided Jira ticket as input (incompatible with service names, `--since`, `--until`)
