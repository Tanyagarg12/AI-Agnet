# Checkpoint and Resume Rules

Every teammate MUST write a checkpoint when it completes a stage, so the pipeline can resume from where it stopped.
In Agent Teams mode, the lead reads the checkpoint to determine which tasks to mark as already-completed when creating the team's task list.

## Checkpoint Location

`memory/tickets/<TICKET-KEY>/checkpoint.json`

## Checkpoint Schema

```json
{
  "ticket_key": "OXDEV-123",
  "pipeline": "e2e-test",
  "completed_stages": ["triage", "explore"],
  "current_stage": "playwright",
  "status": "in_progress",
  "last_updated": "2026-03-06T10:30:00Z",
  "debug_cycles": 0,
  "branch_name": "feat/OXDEV-123-dashboard-filters",
  "stage_outputs": {
    "triage": "memory/tickets/OXDEV-123/triage.json",
    "explore": "memory/tickets/OXDEV-123/exploration.md"
  },
  "error": null
}
```

## Status Values

- `in_progress` -- pipeline is running
- `completed` -- all stages finished successfully
- `failed` -- a stage failed (see `error` field)
- `paused` -- pipeline was intentionally stopped
- `aborted` -- pipeline was aborted because the Jira ticket was closed/cancelled (used by `--watch` mode)

## Stage Output Files

Each stage writes its output to a dedicated file in `memory/tickets/<TICKET-KEY>/`:

| Stage      | Agent        | Dashboard JSON             | Human-Readable         |
|------------|--------------|---------------------------|------------------------|
| triage     | triage       | triage.json               | (same file)            |
| explore    | explorer     | explorer-output.json      | exploration.md         |
| playwright | playwright   | playwright-data.json      | (same file)            |
| implement  | code-writer  | code-writer-output.json   | implementation.md      |
| test       | test-runner  | test-results.json         | (same file)            |
| debug      | debug        | debug-output.json         | debug-history.md       |
| pr         | pr           | pr-output.json            | pr-result.md           |

## Teammate Responsibilities

### At Startup
1. Read `memory/tickets/<TICKET-KEY>/checkpoint.json` if it exists
2. Read the audit log to understand what has already happened
3. Read any prior stage output files referenced in `stage_outputs`

### At Completion of Each Stage
1. Write your output to the designated file in `memory/tickets/<TICKET-KEY>/`
2. Update `checkpoint.json`: add your stage to `completed_stages`, update `current_stage` to the next stage, update `last_updated`
3. If you fail, set `status: "failed"` and populate the `error` field
4. Mark the task as complete in the shared task list

## Resume Behavior (Agent Teams)

When a skill (lead session) starts:
1. Check if `memory/tickets/<TICKET-KEY>/checkpoint.json` exists
2. If it does, read `completed_stages` to determine which stages have already run
3. When creating the agent team's task list, mark completed stages as already-completed tasks
4. Only spawn teammates that have remaining work to do
5. Include all prior stage outputs in teammate spawn prompts for context
6. Inform the user which stages are being skipped
