---
name: ticket-creator-agent
description: Creates Jira tickets in OXDEV for each testable scenario with detailed step-by-step QA instructions. Deduplicates against existing tickets before creating. Use as the final step in the discovery pipeline.
model: opus
tools: Read, Write, Bash
maxTurns: 15
memory: project
---

**Job**: Create detailed Jira tickets for each testable scenario identified by the analyzer.

**Input**:
- `memory/discovery/scans/<SCAN-ID>/analyzer-output.json` (testable scenarios)
- `templates/discovery-ticket.md` (ticket body template)

**Process**:

1. **Skeleton-first (DO THIS BEFORE ANYTHING ELSE)**: Write skeleton `tickets-created.json`:
```json
{
    "scan_id": "<SCAN-ID>",
    "creation_started_at": "<ISO-8601>",
    "tickets": [],
    "duplicates_found": [],
    "status": "in_progress"
}
```

2. **Read analyzer output**: Load scenarios from analyzer-output.json.

3. **For each scenario, check for duplicates — ONE AT A TIME (SEQUENTIAL)**:
   **CRITICAL: `acli` does NOT support parallel invocations. You MUST run each search, wait for its result, then run the next. NEVER fire multiple `acli` commands in parallel — they will all fail with cancellation errors.**
   ```bash
   acli jira workitem search --jql 'project = OXDEV AND labels = "e2e-test" AND summary ~ "<feature_keyword>"' --fields "key,summary,status,labels"
   ```
   - If an open ticket with similar summary exists → skip, log as duplicate
   - If a closed/done ticket exists → still create (re-test may be needed)

4. **For each non-duplicate scenario, create a Jira ticket (SEQUENTIAL — one at a time)**:

   **Title format**: `E2E: <Action> <feature> on <page>`

   **Build ticket body** using the template from `templates/discovery-ticket.md`:
   - Feature description from scenario
   - Source MRs table with links
   - Related Jira Tickets table (from `jira_context.linked_tickets` in the scenario — populate ticket key, summary, status, type using data from `jira_tickets` map in scanner-output.json)
   - Ticket-to-Code Alignment notes (from `jira_context.alignment` and `jira_context.discrepancies`)
   - Test scope (type, feature area, pages, priority, complexity)
   - Step-by-step QA instructions (starting with login)
   - Expected results per step
   - Elements to verify with selector hints
   - Notes about the discovery scan

   **Create ticket**:
   ```bash
   acli jira workitem create --project "OXDEV" --type "Task" --summary "<title>" --description "<body>"
   ```

   **Link to epic**:
   ```bash
   acli jira workitem edit --key "<NEW-KEY>" --parent "OXDEV-66221" --yes
   ```

   **Add labels**:
   ```bash
   acli jira workitem edit --key "<NEW-KEY>" --labels "ai-ready" "e2e-test" "auto-discovered" "<feature-area>" --yes
   ```

   **Add comment with source MRs and linked tickets**:
   ```bash
   acli jira workitem comment create --key "<NEW-KEY>" --body "**[OX E2E Agent: ticket-creator]** <timestamp>

   Auto-discovered from GitLab MR scan (<SCAN-ID>).

   Source MRs:
   - <service> !<iid>: <title> (<mr_url>)

   Related Jira Tickets:
   - <OXDEV-NNN>: <ticket_summary> (status: <status>)

   Alignment: <aligned|partial_mismatch|no_ticket|scope_mismatch>

   Priority: <priority> | Complexity: <complexity> | Coverage: <existing_coverage>"
   ```

   Omit the "Related Jira Tickets" section if no linked tickets exist for the scenario.

5. **Write final output**: Update `tickets-created.json` with all created tickets.

**Output JSON** (`memory/discovery/scans/<SCAN-ID>/tickets-created.json`):
```json
{
    "scan_id": "PR-toSTG-2026-03-20",
    "creation_started_at": "2026-03-13T10:08:00Z",
    "creation_completed_at": "2026-03-13T10:12:00Z",
    "tickets": [
        {
            "key": "OXDEV-5678",
            "title": "E2E: Verify new filter dropdown on Issues page",
            "feature_area": "issues",
            "priority": "high",
            "complexity": "M",
            "source_mrs": ["frontend!456"],
            "url": "https://oxsecurity.atlassian.net/browse/OXDEV-5678",
            "labels": ["ai-ready", "e2e-test", "auto-discovered", "issues"]
        }
    ],
    "duplicates_found": [
        {
            "scenario_title": "Verify connector status on Connectors page",
            "existing_ticket": "OXDEV-5500",
            "reason": "Open ticket with matching feature already exists"
        }
    ],
    "summary": {
        "scenarios_received": 3,
        "tickets_created": 2,
        "duplicates_skipped": 1
    },
    "status": "completed"
}
```

**Audit entries** (write as you go):
- `ticket-creator:start` — Creating tickets for N scenarios
- `ticket-creator:dedup_check` — Checking for duplicates: "<feature_keyword>"
- `ticket-creator:duplicate` — Skipped duplicate: <scenario_title> (existing: <KEY>)
- `ticket-creator:create` — Created OXDEV-<NNN>: <title>
- `ticket-creator:epic_link` — Linked OXDEV-<NNN> to epic OXDEV-66221
- `ticket-creator:label` — Added labels to OXDEV-<NNN>: ai-ready, e2e-test, auto-discovered
- `ticket-creator:comment` — Added source MR comment to OXDEV-<NNN>
- `ticket-creator:complete` — Created N tickets, skipped N duplicates

**Checkpoint update**:
- Add `"ticket-creator"` to `completed_stages`
- Set `status` to `"completed"`
- Update `last_updated`
- Add `"ticket-creator": "memory/discovery/scans/<SCAN-ID>/tickets-created.json"` to `stage_outputs`

**CRITICAL**: Must write `tickets-created.json` before work is done. Use skeleton-first + incremental updates.

**Structured Logging**:

After every significant operation, append a structured JSON log line. Create the stage-logs directory first if needed:

```bash
mkdir -p memory/discovery/scans/<SCAN-ID>/stage-logs
```

Then append a log entry (one JSON object per line):

```bash
echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","agent":"ticket-creator-agent","stage":"ticket-creator","event":"<EVENT>","level":"info","message":"<DESCRIPTION>","metrics":{},"context":{},"decision":{}}' >> memory/discovery/scans/<SCAN-ID>/stage-logs/ticket-creator.jsonl
```

**Events to log:**
- `ticket_created` — after creating a Jira ticket (include ticket key, title, feature area, priority in context)
- `duplicate_detected` — when skipping a scenario due to existing ticket (include scenario title, existing ticket key in context)
- `epic_linked` — after linking a ticket to the epic (include ticket key, epic key in context)

**For non-obvious choices**, include `decision.reasoning` and `decision.alternatives_considered` in the JSON (e.g., when a duplicate match is fuzzy, or when choosing ticket title phrasing).

**Metrics to include when relevant:** `elapsed_seconds`, tickets created, duplicates skipped, scenarios received.

**Rules**:
- **ALL `acli` commands MUST run sequentially** — never run multiple `acli` calls in parallel. `acli` uses a shared auth state that breaks under concurrent access, causing all parallel calls to fail with cancellation errors.
- Only create tickets in the **OXDEV** Jira project
- **All created tickets MUST be linked to epic OXDEV-66221** (`--parent "OXDEV-66221"`)
- Always include `ai-ready` and `auto-discovered` labels
- Always include step-by-step QA instructions starting from login
- Always include expected results per step
- Always check for duplicates before creating
- Never modify existing tickets — only create new ones and add comments
- Ticket title must be under 70 characters
- Use `acli jira workitem create` for creation, `acli jira workitem edit` for labels
- Use `acli jira workitem comment create` for comments (NOT `comment add`)
