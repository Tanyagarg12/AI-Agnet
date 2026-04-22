# Triage Output Schema

```json
{
    "ticket_key": "OXDEV-NNN",
    "feature_area": "issues|sbom|dashboard|policies|settings|connectors|reports|cbom|users",
    "test_type": "ui|api|mixed",
    "complexity": "S|M|L",
    "needs_baseline": true|false,
    "org_name": "organization name",
    "target_pages": ["/issues", "/bom"],
    "summary": "one-line test description",
    "description": "raw Jira description text",
    "jira_url": "https://<site>.atlassian.net/browse/OXDEV-NNN",
    "jira_status": "To Do|In Progress|Done",
    "priority": "low|medium|high|critical",
    "ticket_hash": "md5 hex digest of description+summary"
}
```

## Validation Rules

- `ticket_key` must match pattern `[A-Z]{1,10}-[0-9]{1,6}`
- `feature_area` must be one of: issues, sbom, dashboard, policies, settings, connectors, reports, cbom, users
- `test_type` must be one of: ui, api, mixed
- `complexity` must be one of: S, M, L
- `needs_baseline` must be a boolean
- `org_name` must be a non-empty string
- `target_pages` must have at least 1 entry, each starting with `/`
- `summary` must be a non-empty string (max 255 chars)
- `description` must be a string (raw Jira description; used for `--watch` mode hash comparison)
- `ticket_hash` must be a 32-character hex string (MD5 of description+summary; computed by pipeline lead)

## Feature Area Mapping

Map Jira ticket content to feature areas by keyword matching:

| Feature Area | Keywords |
|-------------|----------|
| issues | issue, vulnerability, finding, detection, code security, supply chain |
| sbom | sbom, bom, software bill, package, dependency, license |
| dashboard | dashboard, overview, widget, summary, metric |
| policies | policy, rule, enforcement, compliance, standard |
| settings | setting, configuration, preference, organization, notification |
| connectors | connector, integration, scanner, tool, pipeline, CI/CD |
| reports | report, export, PDF, download, analytics |
| cbom | cbom, cloud bom, cloud bill, cloud inventory, cloud asset |
| users | user, member, role, permission, invite, team |

## Complexity Assessment

| Complexity | Criteria |
|-----------|----------|
| S | Single page, 3-5 assertions, reuses all existing actions and selectors |
| M | 2-3 pages or tabs, 5-10 assertions, needs some new actions or selectors |
| L | Multi-step flow, 10+ assertions, needs multiple new actions and selectors, data setup required |
