---
name: gp-scan-tickets
description: >
  Scan a ticket platform for testable issues/stories and generate a prioritized
  backlog of automation candidates. Supports Jira, Azure DevOps, GitHub Issues,
  and Linear. Optionally triggers the full pipeline for top candidates.
argument-hint: "[--platform jira|github|ado|linear] [--project KEY] [--label qa-ready] [--status 'Ready for Test'] [--limit 10] [--auto-trigger] [--framework playwright-js]"
---

# GP Scan Tickets — Automation Candidate Discovery

You are scanning a ticket platform to find issues ready for test automation.

## Step 1: Parse Arguments

```
FLAGS:
  --platform      Platform to scan (default: from gp-defaults.json)
  --project       Project key or repo to scan (e.g., PROJ, org/repo)
  --label         Filter by label/tag (default: qa-ready, qa-automation)
  --status        Filter by ticket status (default: Ready for Test, Done, Closed)
  --since         Scan tickets updated since this date (YYYY-MM-DD)
  --limit         Max tickets to return (default: 10)
  --auto-trigger  Automatically trigger /gp-test-agent for top 3 candidates
  --framework     Framework to use for triggered pipelines
```

## Step 2: Load Platform Config

```bash
cat config/platforms/<platform>.json
```

## Step 3: Query for Candidates

Execute platform-specific search query:

**Jira**:
```bash
curl -sf -u "${JIRA_USER}:${JIRA_TOKEN}" \
  "${JIRA_BASE_URL}/rest/api/2/search?jql=project=${PROJECT}+AND+labels+in+(qa-ready,automation-candidate)+AND+status+in+('Ready for Test','Done')&fields=summary,description,priority,labels,status&maxResults=${LIMIT}"
```

**GitHub Issues**:
```bash
gh issue list --repo "${GH_REPO}" --label "qa-ready" --state open --limit ${LIMIT} --json number,title,body,labels,url
```

**Azure DevOps**:
```bash
az boards query --org "${ADO_ORG}" --project "${ADO_PROJECT}" \
  --wiql "SELECT [System.Id],[System.Title],[System.State],[System.Priority] FROM WorkItems WHERE [System.Tags] CONTAINS 'qa-ready' AND [System.WorkItemType] IN ('User Story','Bug')" \
  --output json
```

**Linear**:
```bash
curl -sf -X POST -H "Authorization: ${LINEAR_API_KEY}" -H "Content-Type: application/json" \
  -d '{"query":"{ issues(filter: {labels: {name: {eq: \"qa-ready\"}}}) { nodes { id title description priority state { name } } } }"}' \
  https://api.linear.app/graphql
```

## Step 4: Analyze & Score Candidates

For each ticket found, score automation suitability (0-100):

**Scoring Criteria**:
- Has clear acceptance criteria: +30
- Has step-by-step reproduction: +20
- UI feature (not API-only): +15
- High/Critical priority: +15
- Labeled qa-ready explicitly: +10
- Has screenshots/attachments: +5
- Complexity is S or M (not L/XL): +5

## Step 5: Display Prioritized Backlog

```
📋 Automation Candidates — <PLATFORM> (<PROJECT>)
   Found: <TOTAL_COUNT> tickets | Showing top: <LIMIT>

   #  SCORE  TICKET       PRIORITY  TITLE
   1  [95]   PROJ-456     High      Add filter by severity on Issues page
   2  [87]   PROJ-789     Medium    User can export report as PDF
   3  [82]   PROJ-123     Critical  Login fails with SSO when session expires
   ...

   Scan complete. Use /gp-test-agent <ticket-id> to automate any of these.
```

## Step 6: Auto-Trigger (Optional)

If `--auto-trigger` flag set, trigger `/gp-test-agent` for the top 3 candidates:

For each top-3 ticket:
```
🚀 Triggering pipeline for <TICKET_ID>...
   /gp-test-agent <TICKET_ID> --framework <FRAMEWORK> --auto
```

## Memory Update

Append scan summary to `memory/gp/platform-patterns.md`:
- Total tickets scanned
- Average score of candidates
- Platform-specific field availability (which fields were populated)
- Any authentication issues encountered
