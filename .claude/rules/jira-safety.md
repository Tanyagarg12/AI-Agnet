# Jira Safety Rules

These rules protect Jira data integrity.

## NEVER Do
- NEVER delete a Jira ticket or issue
- NEVER change a ticket's issue type
- NEVER reassign tickets to different users
- NEVER change ticket priority without explicit user approval
- NEVER modify ticket summary or description

## ALLOWED Jira Operations
- Search tickets (any project)
- View ticket details (any project)
- Add comments (only on OXDEV tickets, always include agent name and timestamp)
- Add labels (ai-ready, ai-in-progress, ai-done, ai-failed, e2e-test, auto-discovered, onprem-incompatible, stage:*)
- Remove labels (only ai-* labels, only on OXDEV tickets)
- Read ticket data (search, get issue details)
- Create tickets (only OXDEV project, only by ticket-creator agent, always with `ai-ready` + `auto-discovered` labels)

## Project Scope for Writes
- Only the **OXDEV** Jira project is allowed for write operations
- Read operations (search, view, comment list) are allowed on any project
- Create, edit, comment-add, and label operations MUST target OXDEV tickets only

## Label Conventions
- `ai-ready`: ticket is ready for autonomous processing
- `ai-in-progress`: agent pipeline is currently working on this ticket
- `ai-done`: pipeline completed successfully, MR created
- `ai-failed`: pipeline failed, see comments for details
- `e2e-test`: identifies ticket as an E2E test ticket
- `auto-discovered`: ticket was auto-created by the discovery pipeline
- `onprem-incompatible`: test could not be adapted for on-prem environments
- `stage:*`: pipeline stage labels (stage:explored, stage:implemented, stage:tested, etc.)

## acli Concurrency (CRITICAL)

**NEVER run multiple `acli` commands in parallel.** `acli` uses a shared auth/session state that breaks under concurrent access — all parallel calls will fail with cancellation errors. Always run `acli` commands sequentially: wait for one to complete before starting the next.

## acli Command Syntax (CORRECT)

NEVER use `acli jira issue label add` or `acli jira workitem update --labels` — these are invalid commands.
NEVER use `--yes` with `acli jira workitem create` — the `create` subcommand does not support `--yes` (only `edit` does).

**Add labels:**
```bash
acli jira workitem edit --key "OXDEV-123" --labels "ai-in-progress" --yes
```

**Remove labels:**
```bash
acli jira workitem edit --key "OXDEV-123" --remove-labels "ai-ready" --yes
```

**View ticket:**
```bash
acli jira workitem view OXDEV-123 --fields "key,summary,description,labels,status,issuetype,priority"
```

**Add comment:**
```bash
acli jira workitem comment create --key "OXDEV-123" --body "comment text"
```

## Comment Format
All Jira comments from the agent must follow this format:
```
**[OX E2E Agent: <agent-name>]** <timestamp>

<content>
```
