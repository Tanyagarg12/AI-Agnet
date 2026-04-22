# Discovery Ticket Template

Use this template when creating Jira tickets from discovered changes.

## Jira Ticket Body Format

```
h2. Feature Under Test

{feature_description}

h2. Source Changes

|| MR || Service || Title || Merged ||
| [!{mr_iid}|{mr_url}] | {service_name} | {mr_title} | {merged_at} |

h2. Related Jira Tickets

|| Ticket || Summary || Status || Type ||
| [{ticket_key}|{jira_base_url}/browse/{ticket_key}] | {ticket_summary} | {ticket_status} | {ticket_type} |

h2. Ticket-to-Code Alignment

{alignment_notes}

h2. Test Scope

* *Test Type*: {UI|API|mixed}
* *Feature Area*: {feature_area}
* *Target Pages*: {page_list}
* *Priority*: {high|medium|low}
* *Estimated Complexity*: {S|M|L}

h2. Step-by-Step QA Instructions

# Navigate to {login_url}
# Login with test credentials
# Close "What's New" modal if present
# Navigate to {target_page}
# {step_description} — *Expected*: {expected_result}
# {step_description} — *Expected*: {expected_result}
# {step_description} — *Expected*: {expected_result}

h2. Expected Results

* {assertion_1}
* {assertion_2}
* {assertion_3}

h2. Elements to Verify

|| Element || Type || Selector Hint ||
| {element_name} | {button|input|table|dropdown|tab} | {data-testid or class hint} |

h2. Notes

* Auto-discovered by QA E2E Discovery Pipeline
* Source MRs merged between {scan_from} and {scan_to}
* {additional_context}
```

## Field Descriptions

| Field | Description |
|-------|-------------|
| `feature_description` | One-paragraph summary of what the feature does |
| `mr_iid` / `mr_url` | GitLab MR IID and full URL |
| `service_name` | Source service (frontend, connectors, etc.) |
| `feature_area` | E2E framework feature area (issues, sbom, dashboard, etc.) |
| `page_list` | Comma-separated list of app pages/routes |
| `step_description` | Human-readable test step |
| `expected_result` | What should happen after the step |
| `assertion_N` | Specific assertion to verify |
| `element_name` | UI element that needs a selector |
| `scan_from` / `scan_to` | Date range of the discovery scan |
| `ticket_key` | Related OXDEV ticket key (from MR references) |
| `ticket_summary` | Summary of the related Jira ticket |
| `ticket_status` | Status of the related Jira ticket (e.g., Done, In Progress) |
| `ticket_type` | Issue type of the related Jira ticket (e.g., Bug, Story, Task) |
| `jira_base_url` | Jira instance URL (from JIRA_BASE_URL env var) |
| `alignment_notes` | Notes on whether MR changes match the Jira ticket description. Includes any discrepancies flagged during validation. |

## Title Format

```
E2E: <Action> <feature> on <page>
```

Examples:
- `E2E: Verify new filter dropdown on Issues page`
- `E2E: Test connector status badges on Connectors page`
- `E2E: Validate report export functionality on Reports page`

## Labels

Always include these labels on created tickets:
- `ai-ready` — marks ticket for autonomous processing
- `e2e-test` — identifies as E2E test ticket
- `auto-discovered` — created by discovery pipeline
- `<feature-area>` — the feature area (e.g., `issues`, `dashboard`)
