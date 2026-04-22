# Audit Logging Rules

Every agent MUST log every Git, Jira, and framework operation to the ticket's audit log.

## Audit Log Location

All audit data lives in `memory/tickets/<TICKET-KEY>/` relative to the project root.

## What to Log

Every MCP tool call that touches Git, Jira, or the framework MUST be logged. This includes:
- Jira: reading tickets, adding labels, adding comments
- Git: creating branches, committing files, pushing, creating MRs
- Framework: creating test files, modifying actions, updating selectors
- Test runs: executing tests, capturing results, debug iterations

## Audit Log Format

Append entries to `memory/tickets/<TICKET-KEY>/audit.md`:

```markdown
### [<ISO-8601 timestamp>] <agent-name>
- **Action**: <jira|git|framework|test>:<operation>
- **Target**: <ticket-key or repo/branch or file-path>
- **Result**: <success|failure>
- **Details**: <one-line human-readable summary>
```

### Example Entries

```markdown
### [2026-03-06T10:15:00Z] triage-agent
- **Action**: jira:read_issue
- **Target**: OXDEV-123
- **Result**: success
- **Details**: Read ticket OXDEV-123 -- feature, priority P2, UI test needed

### [2026-03-06T10:16:00Z] explorer-agent
- **Action**: framework:read_selectors
- **Target**: selectors/dashboard.json
- **Result**: success
- **Details**: Read 24 selectors for dashboard feature

### [2026-03-06T10:20:00Z] code-writer-agent
- **Action**: framework:create_test
- **Target**: tests/UI/dashboard/dashboardFilters.test.js
- **Result**: success
- **Details**: Created new test file with 5 test cases for dashboard filter validation

### [2026-03-06T10:25:00Z] test-runner-agent
- **Action**: test:run
- **Target**: tests/UI/dashboard/dashboardFilters.test.js
- **Result**: failure
- **Details**: 3/5 tests passed, 2 failures in filter assertion (debug cycle 1/3)
```

## Rules

1. Log AFTER each operation with the result — no need for before/after pairs
2. Never skip logging even if the operation fails — log failures with error details
3. The audit log is append-only — never delete or modify existing entries
4. Each agent reads the existing audit log at startup to understand what has already happened
5. Use ISO-8601 timestamps (UTC)
