---
name: qa-triage-ticket
description: Triage a Jira ticket by classifying its feature area, test type, complexity, and target pages. No team needed -- the lead performs triage directly.
disable-model-invocation: true
argument-hint: "[ticket-key]"
---

# Triage E2E Test Ticket

Classify and prepare a Jira ticket for the E2E test pipeline.

## Usage

```
/qa-triage-ticket OXDEV-123
```

## Process

### Step 1: Check for Existing Checkpoint

Read `memory/tickets/$ARGUMENTS/checkpoint.json` if it exists.
- If triage is already in `completed_stages`, inform the user and ask if they want to re-triage or skip.
- If it does not exist, create directory `memory/tickets/$ARGUMENTS/`.

### Step 2: Read Jira Ticket

1. Add label `ai-in-progress` to the Jira ticket via `acli`
2. Read the Jira ticket via `acli` -- get summary, description, labels, components, priority
3. Read `memory/framework-catalog.md` for known framework structure

### Step 3: Classify Ticket

Follow the classification logic in `.claude/agents/triage-agent.md`:

1. **Feature area** -- match ticket to one of: issues, sbom, dashboard, policies, settings, connectors, reports, cbom, users
   - Use keyword matching from ticket summary and description
   - Cross-reference with existing test directories in `framework/tests/UI/`

2. **Test type** -- determine: ui, api, mixed
   - UI: ticket mentions page interactions, navigation, buttons, forms
   - API: ticket mentions API endpoints, GraphQL queries, response validation
   - Mixed: ticket requires both UI and API validation

3. **Complexity** -- assess: S, M, L
   - S: single page, few assertions, reuses existing actions
   - M: multiple pages or tabs, moderate assertions, some new actions needed
   - L: multi-step flows, complex data setup, many new actions and selectors

4. **Baseline** -- does the test need baseline data (needs_baseline: true/false)?
   - True if the test validates specific data values, counts, or states
   - False if the test only validates UI elements and navigation

5. **Target pages** -- list URLs the test needs to visit (e.g., `/issues`, `/bom`, `/settings`)

6. **Org name** -- determine which org to use for testing
   - Read from `process.env.SANITY_ORG_NAME` or ticket description

7. **Summary** -- one-line test description

### Step 4: Write Triage Output

Write triage output to `memory/tickets/$ARGUMENTS/triage.json`:

```json
{
    "ticket_key": "$ARGUMENTS",
    "feature_area": "<area>",
    "test_type": "<type>",
    "complexity": "<S|M|L>",
    "needs_baseline": true|false,
    "org_name": "<organization name>",
    "target_pages": ["/page1", "/page2"],
    "summary": "one-line test description",
    "jira_url": "https://$ATLASSIAN_SITE_NAME/browse/$ARGUMENTS",
    "jira_status": "<ticket status>",
    "priority": "<low|medium|high|critical>"
}
```

### Step 5: Write Checkpoint

Write checkpoint to `memory/tickets/$ARGUMENTS/checkpoint.json`:
```json
{
  "ticket_key": "$ARGUMENTS",
  "pipeline": ["triage", "explorer", "playwright", "code-writer", "test-runner", "pr"],
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

### Step 6: Write Audit Log

Append to `memory/tickets/$ARGUMENTS/audit.md`:
```
### [<ISO-8601>] triage-agent
**Action**: Triage ticket $ARGUMENTS
**Target**: memory/tickets/$ARGUMENTS/triage.json
**Result**: Classified as <feature_area>, <test_type>, complexity <complexity>
**Details**: Target pages: <pages>, needs baseline: <true/false>
```

### Step 7: Add Jira Comment

Add a comment with the triage summary:
```
**[QA Agent: triage-agent]** <timestamp>

**Triage Complete**

| Field        | Value                |
|--------------|----------------------|
| Feature area | <feature_area>       |
| Test type    | <test_type>          |
| Complexity   | <complexity>         |
| Target pages | <pages>              |
| Baseline     | <yes/no>             |

**Pipeline**: triage > explorer > playwright > code-writer > test-runner > pr
```

### Step 8: Report to Dashboard

Report triage completion:
```bash
./scripts/report-to-dashboard.sh $ARGUMENTS triage
```

### Step 9: Present Results

Present the triage result and suggest next steps:
- Proceed with the full pipeline: `/qa-autonomous-e2e $ARGUMENTS`
- Explore framework only: `/qa-explore-framework $ARGUMENTS`
- Gather locators only: `/qa-gather-locators $ARGUMENTS`
- Stop and review manually

## Arguments

- `$ARGUMENTS` -- the Jira ticket key (e.g., OXDEV-123)
