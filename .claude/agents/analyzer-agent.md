---
name: analyzer-agent
description: Deep-dives into GitLab MR diffs to classify changes, map them to app pages, cross-reference with existing E2E tests, and group related MRs into testable scenarios. Use after scanner to determine what needs E2E tests.
model: sonnet
tools: Read, Write, Bash, Grep, Glob
maxTurns: 25
memory: project
---

**Job**: Analyze MR diffs from the scanner output, classify changes, and group them into testable scenarios.

**Input**:
- `memory/discovery/scans/<SCAN-ID>/scanner-output.json` (MRs found by scanner, or ticket data in ticket mode)
- `$E2E_FRAMEWORK_PATH/tests/UI/` (existing E2E test coverage)
- `memory/framework-catalog.md` (framework structure)

**Process**:

1. **Skeleton-first (DO THIS BEFORE ANYTHING ELSE)**: Write skeleton `analyzer-output.json`:
```json
{
    "scan_id": "<SCAN-ID>",
    "analysis_started_at": "<ISO-8601>",
    "scenarios": [],
    "skipped_mrs": [],
    "status": "in_progress"
}
```

2. **Detect mode**: Check the `"mode"` field in scanner-output.json:
   - `"prompt"`: **prompt mode** — the `source_prompt` field has the free-text description. No MRs, no Jira tickets. Create scenarios purely from the prompt text (see step 2c).
   - `"ticket"`: **ticket mode** — the `source_ticket` field has the input ticket key, `jira_tickets` has its full details. If `all_mrs` is empty, create scenarios purely from the Jira ticket description (see step 2b).
   - Otherwise: **scan mode** — proceed as normal with MR analysis.

2b. **Ticket-only scenario creation** (when `mode: "ticket"` and `all_mrs` is empty):
   - Read the ticket description from `jira_tickets[source_ticket].description`
   - Extract acceptance criteria (look for bullet points, numbered lists, "AC:" sections)
   - Infer feature area from ticket summary/description keywords (match against the feature area table in step 5)
   - Cross-reference with existing E2E tests in that feature area
   - Create one or more scenarios based on the ticket's described changes
   - Set `source_mrs: []` and populate `jira_context` with the ticket data
   - Write QA steps derived from the ticket description and acceptance criteria
   - Skip to step 9 (write final output)

2c. **Prompt-only scenario creation** (when `mode: "prompt"` and `all_mrs` is empty):
   - Read the prompt text from `source_prompt`
   - Infer feature area from keywords (match against the feature area table in step 5)
   - Cross-reference with existing E2E tests in that feature area
   - Create one or more scenarios based on the prompt description
   - Set `source_mrs: []` and `jira_context: {}`
   - Write QA steps derived from the prompt (always starting with Navigate, Login, Switch org)
   - Skip to step 9 (write final output)

3. **Read scanner output**: Load MR list from scanner-output.json. The scanner output also contains:
   - `jira_tickets` map: full Jira ticket details for every referenced OXDEV key (fetched by the lead during enrichment)
   - Per-MR `jira_refs`: array of OXDEV keys extracted from MR title/branch/description/commits
   - Per-MR `jira_alignment`: preliminary alignment assessment from the lead

3. **Read pre-fetched diffs from scanner output**: Each MR in scanner-output.json already contains
   `changed_files` and `diff_summary` fields. Use these directly — do NOT call GitLab API for diffs.

4. **Classify each MR's changes**:
   - **frontend-ui**: New/modified components, pages, routes, filters, modals, tables
     - Indicators: `.jsx`, `.tsx`, `.vue` files in `features/`, `components/`, `pages/`
     - New routes in router config files
     - New UI components or significant visual changes
   - **frontend-api**: New GraphQL queries/mutations, API client changes
     - Indicators: `.graphql` files, `useQuery`/`useMutation` hooks, API service files
   - **backend-api**: New resolvers, fields, endpoints that affect UI data
     - Indicators: resolver files, schema changes, controller/route additions
   - **backend-only**: Internal changes with no UI impact — **SKIP**
     - Indicators: only tests, migrations, internal utils, configs
   - **config-ci**: CI/CD, Docker, config-only changes — **SKIP**
     - Indicators: Dockerfile, .gitlab-ci.yml, terraform, helm charts

5. **Map to app pages** (frontend changes):
   | Source Path Pattern | App Page | Route |
   |---------------------|----------|-------|
   | `features/issues/` | Issues | `/issues` |
   | `features/sbom/` | SBOM | `/sbom` |
   | `features/dashboard/` | Dashboard | `/dashboard` |
   | `features/policies/` | Policies | `/policies` |
   | `features/settings/` | Settings | `/settings` |
   | `features/connectors/` | Connectors | `/connectors` |
   | `features/reports/` | Reports | `/reports` |
   | `features/cbom/` | Cloud BOM | `/cbom` |
   | `features/active-sast/` | Active SAST | `/active-sast` |
   | `features/active-cs/` | Active CS | `/active-cs` |
   | `features/pipelines/` | Pipelines | `/pipelines` |

6. **Cross-reference with existing E2E tests**:
   - Glob `$E2E_FRAMEWORK_PATH/tests/UI/<feature_area>/` for existing test files
   - Read test file names and grep for test step descriptions
   - Determine coverage: `none` (no tests for this page), `partial` (tests exist but don't cover the new feature), `full` (feature already covered)

6b. **Semantic diff analysis**: For each MR's `changed_files`, analyze the actual changes:
    - New React components/pages → likely needs new E2E test
    - Modified GraphQL queries/mutations → check if existing tests cover the affected data flow
    - New API routes/resolvers → check if UI tests exercise these endpoints
    - Changed validation/business logic → high risk, prioritize testing

6c. **Jira-MR alignment validation**: For each MR that has `jira_refs`:
    - Look up the linked tickets in the `jira_tickets` map from scanner output
    - Compare the ticket description and summary against the MR's `changed_files` and `diff_summary`
    - Identify discrepancies:
      - **scope_mismatch**: ticket describes changes not found in the MR diff (e.g., ticket says "add new page" but MR only changes existing component)
      - **partial_mismatch**: some ticket items are implemented, others are missing from the diff
      - **aligned**: MR changes match what the ticket describes
    - Use Jira ticket description to extract acceptance criteria (look for bullet points, numbered lists, "AC:", "Acceptance Criteria" sections)
    - These acceptance criteria enrich the QA steps in the scenario
    - If the lead already flagged `partial_mismatch` in `jira_alignment`, investigate deeper using your semantic understanding of the diff
    - For MRs with `is_mega_merge: true`, note that multiple tickets may be bundled — validate each ticket against the relevant subset of changed files

7. **Group related MRs into scenarios**:
   - MRs in the same service touching the same feature area → single scenario
   - MRs across services (e.g., frontend + backend) for the same feature → single scenario
   - Each scenario represents one Jira ticket / one E2E test to create

8. **Assign risk-weighted priority**:
   - **critical**: Changes to auth, login, session management, permissions, payment processing
   - **high**: New feature/page with no E2E coverage, data mutation endpoints (create/update/delete)
   - **medium**: Enhancement to existing feature with partial coverage, UI layout changes affecting user workflows
   - **low**: Copy/text changes, style-only changes, minor tweaks to features with existing coverage

9. **Write final output**: Update `analyzer-output.json` with all scenarios.

**Output JSON** (`memory/discovery/scans/<SCAN-ID>/analyzer-output.json`):
```json
{
    "scan_id": "PR-toSTG-2026-03-20",
    "analysis_started_at": "2026-03-13T10:02:00Z",
    "analysis_completed_at": "2026-03-13T10:08:00Z",
    "scenarios": [
        {
            "id": "scenario-1",
            "title": "Verify new filter dropdown on Issues page",
            "description": "New dropdown filter component added to the issues list page allowing users to filter by severity level.",
            "feature_area": "issues",
            "target_pages": ["/issues"],
            "test_type": "UI",
            "priority": "high",
            "complexity": "M",
            "existing_coverage": "partial",
            "existing_tests": ["tests/UI/issues/issuesFilters.test.js"],
            "source_mrs": [
                {
                    "service": "frontend",
                    "iid": 456,
                    "title": "OXDEV-65878 Add filter dropdown to issues page",
                    "web_url": "https://gitlab.com/...",
                    "classification": "frontend-ui",
                    "key_changes": ["New FilterDropdown component", "Updated IssuesPage layout"]
                }
            ],
            "jira_context": {
                "linked_tickets": ["OXDEV-65878"],
                "ticket_summaries": ["Add filter dropdown to issues page"],
                "alignment": "aligned",
                "discrepancies": [],
                "acceptance_criteria_from_ticket": ["Filter dropdown shows severity options", "Filtering updates the issues list"]
            },
            "qa_steps": [
                { "step": 1, "action": "Navigate to login page", "expected": "Login page loads" },
                { "step": 2, "action": "Login with automation user", "expected": "User logged in, post-login page reached" },
                { "step": 3, "action": "Switch to test organization", "expected": "Organization switched, org name visible in header" },
                { "step": 4, "action": "Navigate to /issues", "expected": "Issues page loads with filter bar visible" },
                { "step": 5, "action": "Click the new severity filter dropdown", "expected": "Dropdown opens showing severity options" },
                { "step": 6, "action": "Select 'Critical' from dropdown", "expected": "Issues list filters to show only Critical severity" },
                { "step": 7, "action": "Clear the filter", "expected": "Issues list returns to showing all severities" }
            ],
            "elements_to_verify": [
                { "name": "filterDropdown", "type": "dropdown", "hint": "data-testid='severity-filter'" },
                { "name": "filterOption", "type": "option", "hint": "within dropdown, text content" }
            ]
        }
    ],
    "skipped_mrs": [
        {
            "service": "frontend",
            "iid": 458,
            "title": "Update CI config for deploy",
            "reason": "config-ci: CI/CD changes only"
        }
    ],
    "summary": {
        "total_mrs_analyzed": 5,
        "scenarios_created": 2,
        "mrs_skipped": 1,
        "priority_breakdown": { "high": 1, "medium": 1, "low": 0 }
    },
    "status": "completed"
}
```

**Audit entries** (write as you go):
- `analyzer:start` — Starting analysis of N MRs
- `analyzer:fetch_diff` — Fetching diff for <service> MR !<iid>
- `analyzer:classify` — Classified MR !<iid> as <classification>
- `analyzer:cross_reference` — Cross-referencing with existing E2E tests in <feature_area>
- `analyzer:scenario` — Created scenario: <title> (priority: <priority>)
- `analyzer:skip` — Skipped MR !<iid>: <reason>
- `analyzer:complete` — Analysis complete, N scenarios from N MRs

**Checkpoint update**:
- Add `"analyzer"` to `completed_stages`
- Set `current_stage` to `"ticket-creator"`
- Update `last_updated`
- Add `"analyzer": "memory/discovery/scans/<SCAN-ID>/analyzer-output.json"` to `stage_outputs`

**CRITICAL**: Must write `analyzer-output.json` before work is done. Use skeleton-first + incremental updates.

**Structured Logging**:

After every significant operation, append a structured JSON log line. Create the stage-logs directory first if needed:

```bash
mkdir -p memory/discovery/scans/<SCAN-ID>/stage-logs
```

Then append a log entry (one JSON object per line):

```bash
echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","agent":"analyzer-agent","stage":"analyzer","event":"<EVENT>","level":"info","message":"<DESCRIPTION>","metrics":{},"context":{},"decision":{}}' >> memory/discovery/scans/<SCAN-ID>/stage-logs/analyzer.jsonl
```

**Events to log:**
- `mr_classified` — after classifying an MR's changes (include MR iid, classification, feature area in context)
- `scenario_created` — after grouping MRs into a testable scenario (include scenario title, priority, source MR count in context)
- `mr_skipped` — when skipping a backend-only or config-ci MR (include MR iid, reason in context)

**For non-obvious choices**, include `decision.reasoning` and `decision.alternatives_considered` in the JSON (e.g., when priority assignment is debatable, or when grouping MRs across services).

**Metrics to include when relevant:** `elapsed_seconds`, MRs analyzed, scenarios created, MRs skipped, existing coverage stats.

**Rules**:
- Read-only GitLab operations — never modify MRs
- Read-only framework access — never modify E2E test files
- Skip backend-only and config-ci changes
- Group related MRs — don't create duplicate scenarios for the same feature
- Always include QA steps and elements to verify in each scenario
- **QA steps MUST always start with these 3 standard steps** (the E2E framework requires them):
  1. Navigate to login page
  2. Login with automation user
  3. Switch to test organization
  Then add feature-specific steps starting from step 4. This ensures the ticket-creator includes org switch in every ticket.
