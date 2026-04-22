# Global Limits

These limits are non-negotiable and apply to ALL agents and skills in this project.

## Debug Cycle Limits
- Maximum 3 **stalled** debug cycles per test (a cycle is "stalled" only if it made no progress — same or fewer tests passing). Cycles that fix at least one more test don't count toward the limit.
- After 3 stalled debug cycles, pipeline stops with `ai-failed` label and detailed Jira comment
- Debug cycle count is tracked in `checkpoint.json` under `debug_cycles`
- Cycle history is appended to `memory/tickets/<TICKET-KEY>/debug-history.md`

## Project Scope
- Only work with tickets in the Jira project **OXDEV**
- Do NOT read, modify, or interact with tickets in other Jira projects

## Target Repository
- All test code lives in: `$E2E_FRAMEWORK_PATH/`
- Do NOT modify files outside this repository unless explicitly instructed

## MR Target Branch
- Default MR target: `developmentV2`
- Do NOT target `main`, `master`, `development`, or any other branch

## Turn Limits by Agent

### Implementation Pipeline
| Agent       | Max Turns |
|-------------|-----------|
| triage      | 10        |
| explorer    | 25        |
| playwright  | 40        |
| code-writer | 50        |
| test-runner | 15        |
| debug       | 40        |
| pr          | 10        |

### Discovery Pipeline
| Agent          | Max Turns |
|----------------|-----------|
| scanner        | 10        |
| analyzer       | 25        |
| ticket-creator | 15        |

## Output File Rule (CRITICAL)

Every agent MUST write its output file before completing. This is non-negotiable.

| Agent       | Required Output Files |
|-------------|----------------------|
| triage      | `memory/tickets/<KEY>/triage.json` |
| explorer    | `memory/tickets/<KEY>/exploration.md` |
| playwright  | `memory/tickets/<KEY>/playwright-data.json` |
| code-writer | `memory/tickets/<KEY>/code-writer-output.json` + `implementation.md` |
| test-runner | `memory/tickets/<KEY>/test-results.json` |
| debug       | `memory/tickets/<KEY>/debug-history.md` + `test-results.json` |
| pr          | `memory/tickets/<KEY>/pr-result.md` |

### Discovery Pipeline
| Agent          | Required Output Files |
|----------------|----------------------|
| scanner        | `memory/discovery/scans/<SCAN-ID>/scanner-output.json` |
| analyzer       | `memory/discovery/scans/<SCAN-ID>/analyzer-output.json` |
| ticket-creator | `memory/discovery/scans/<SCAN-ID>/tickets-created.json` |

**Strategy — Incremental Writes (agents CANNOT count their own turns):**

1. Write a skeleton output file as your VERY FIRST action (before any real work)
2. Update the output file AFTER EVERY major action (not just at the end)
3. The lead verifies output files exist after each teammate completes — if missing, the lead writes fallback output directly from git/audit data (never re-spawns, which wastes more turns)

Do NOT rely on "reserve last N turns" — agents routinely exhaust all turns on the main task and never reach the output-writing step. Incremental writes are the only reliable pattern.

## Test Execution Rule (CRITICAL)

When running Playwright tests, **ALWAYS** use `--retries=0 --trace on`:

```bash
envFile=.env.stg npx playwright test <test-file> --retries=0 --trace on
```

- **`--retries=0`**: The pipeline handles retries through debug cycles. Playwright's built-in retries double execution time for zero benefit — the agent needs to see the failure immediately, fix the code, and re-run.
- **`--trace on`**: The config has `trace: "on-first-retry"` but with retries disabled, traces are never captured. This flag ensures traces are always generated. Traces contain DOM snapshots, network logs, console output, and step-by-step screenshots — critical data for the debug agent to analyze failures without needing to reproduce them in a live browser.

## Banned Patterns

- **NEVER use `page.waitForLoadState("networkidle")`** — this is a complex app with constant background network activity (WebSockets, polling, analytics). `networkidle` will hang indefinitely. Use explicit waits instead: `page.waitForSelector()`, `page.waitForResponse()`, `page.waitForTimeout()`, or `page.waitForLoadState("domcontentloaded")`.

## Cost Optimization
- Use the cheapest model that can handle each task
- triage, pr, and scanner agents use haiku
- explorer, test-runner, and analyzer agents use sonnet
- playwright agent uses sonnet; code-writer, debug, and ticket-creator agents use opus
