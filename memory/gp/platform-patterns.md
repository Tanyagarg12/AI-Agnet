# GP Platform Patterns

Accumulated learnings from ticket platform interactions across all GP pipeline runs.
Updated by `gp-learner-agent` after each run.

---

## Jira (jira-any)

### Field Availability
- `customfield_10016` — Acceptance Criteria: present in ~70% of projects using standard Jira templates
- `customfield_10028` — Alternative AC field used by some teams
- When AC field is null: parse markdown headers in description (`## Acceptance Criteria`, `**AC:**`)
- `labels` array: always present but often empty on legacy tickets

### API Behavior
- Always use `?expand=renderedFields` to get HTML-formatted descriptions (easier to parse than Jira wiki markup)
- Rate limit: 100 requests/minute on Cloud; use pagination for bulk queries
- Attachment URLs require auth (Bearer token in header)

### Common Issues
- 401 errors: Token may have expired; check ATLASSIAN_API_TOKEN
- Empty AC fields: Most teams write AC in description body; use markdown extraction fallback
- Long descriptions with complex tables: may need HTML parsing via `renderedFields`

---

## GitHub Issues (github-issues)

### Field Availability
- No dedicated AC field — always use markdown section extraction
- Look for these sections: `## Acceptance Criteria`, `## AC`, `## Done When`, `**Acceptance Criteria:**`
- `labels` array reliably present
- `milestone` useful for sprint tracking

### API Behavior
- Rate limit: 60 req/hr unauthenticated, 5000/hr with token
- Use `gh` CLI when available (simpler auth than raw curl)
- `gh issue view --json` output is consistent and well-structured

### Common Issues
- No formal AC structure: many GitHub issues are informal bug reports
- Extract steps from numbered lists in the body
- Priority often expressed via labels (`priority: high`, `p1`, `critical`)

---

## Azure DevOps (azure-devops)

### Field Availability
- `Microsoft.VSTS.Common.AcceptanceCriteria` — well-populated on User Stories
- `System.Description` — often contains detailed requirements on larger teams
- Work item type matters: User Story has AC, Bug/Task may not

### API Behavior
- Requires `az` CLI with `devops` extension: `az extension add --name azure-devops`
- Or use REST API with Basic Auth: `Authorization: Basic <base64(user:PAT)>`
- Organization URL format: `https://dev.azure.com/<org>/`

### Common Issues
- HTML in description fields (rich text editor) — strip HTML tags
- Work item relations (parent/child) not in default API response; use `?$expand=relations`

---

## Linear (linear)

### Field Availability
- No dedicated AC field — use markdown extraction from description
- Priority as integer (0=no priority, 1=urgent, 2=high, 3=medium, 4=low)
- Labels via GraphQL nodes array

### API Behavior
- GraphQL API only — requires specific query construction
- API key in header: `Authorization: <key>` (NOT `Bearer <key>`)
- Rate limit: 500 complexity points/minute

### Common Issues
- GraphQL complexity limits: break large queries into smaller ones
- Issue ID vs identifier: use `identifier` (e.g., "PROJ-123") not internal UUID

---

## ServiceNow (servicenow)

### Field Availability
- `acceptance_criteria` — custom field, varies by instance configuration
- `u_user_story` — custom table for user stories (varies by org)
- Check `sys_class_name` to determine which table to query

### API Behavior
- Instance-specific URLs: `https://<instance>.service-now.com`
- Basic auth only (no token); credentials must be in env
- Table API: `/api/now/table/<table_name>`

### Common Issues
- Table names vary by organization — verify `sys_class_name` with admin
- Rich text in description fields — use `sysparm_display_value=true` for plain text
