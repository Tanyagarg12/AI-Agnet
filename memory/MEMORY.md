# QA E2E Agent Team Memory

All memory lives under a single `memory/` directory.
Pipeline skills use Agent Teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`).

## Directory Structure

```
memory/
  MEMORY.md                  # This file (auto-loaded, git tracked)
  framework-catalog.md       # E2E framework structure summary (git tracked)
  selector-patterns.md       # Selector patterns discovered by agents (git tracked)
  test-patterns.md           # Common test patterns discovered (git tracked)
  agents/                    # Per-agent-type learnings (git tracked)
    explorer.md
    playwright.md
    code-writer.md
    debug.md
  tickets/                   # Per-ticket runtime data (gitignored)
    <TICKET-KEY>/
      triage.json, audit.md, checkpoint.json, ...
```

## Index

### Global Files
- **framework-catalog.md** -- E2E framework structure summary with directory layout, key files, patterns
- **selector-patterns.md** -- Selector patterns and data-testid conventions discovered during browser exploration
- **test-patterns.md** -- Common test patterns and conventions discovered across test implementations

### Per-Agent-Type Files (`agents/`)
- **explorer.md** -- Framework exploration strategies, useful grep patterns, action/selector discovery tips
- **playwright.md** -- Browser exploration patterns, element types, locator extraction strategies
- **code-writer.md** -- Code convention discoveries, reuse patterns, common pitfalls
- **debug.md** -- Common failure patterns, fix strategies, timeout tuning notes

### Dashboard Integration
- **Reporting script**: `scripts/report-to-dashboard.sh` -- bridges agent outputs to dashboard API
- **Config**: `dashboard.config.json` + `DASHBOARD_URL` env var
- **Endpoint**: `/api/e2e-agent/report`

## How to Use

- Teammates should read this memory before starting work
- Each agent reads its own `agents/<role>.md` file at startup
- Update framework-catalog.md when you discover new framework details
- Add to selector-patterns.md when you discover data-testid conventions
- Add to test-patterns.md when you identify reusable test patterns
- Update your agent-type file after completing work

## Memory Architecture

### Per-Ticket Shared Memory (`memory/tickets/<TICKET-KEY>/`)

All agents working on a ticket read and write to the same directory. This is the shared workspace for a single E2E test pipeline run:

| File | Written By | Read By | Purpose |
|------|-----------|---------|---------|
| `triage.json` | Lead (triage) | All agents | Ticket classification, feature area, target pages |
| `checkpoint.json` | All agents | All agents | Pipeline state, completed stages, resume data |
| `audit.md` | All agents | All agents | Chronological log of all operations |
| `exploration.md` | Analyst (explorer) | Developer, Browser | Framework patterns, reusable components found |
| `playwright-data.json` | Browser (playwright) | Developer | Element locators gathered from live app |
| `implementation.md` | Developer (code-writer) | Tester, Debug | Test file location, actions created, selectors added |
| `test-results.json` | Tester (test-runner) | Developer (debug) | Test execution results, pass/fail per test |
| `debug-history.md` | Developer (debug) | Developer (next cycle) | Debug attempts and outcomes across cycles |
| `pr-result.md` | Lead (pr) | Lead (finalize) | MR URL, labels applied, final status |

**Key flow**: `exploration.md` is created by the explorer and consumed by the developer. `playwright-data.json` provides locators from the live app to the developer. `test-results.json` flows from tester back to developer for debug loops.

### Global Memory (root of `memory/`)

Persistent knowledge that accumulates across tickets. Agents update these files when they discover new information:

- **framework-catalog.md** -- Updated when agents discover new framework patterns or structure changes
- **selector-patterns.md** -- Updated when browser agent finds new data-testid conventions
- **test-patterns.md** -- Updated when code-writer discovers reusable test patterns

### Per-Agent-Type Memory (`memory/agents/`)

Each agent role has a persistent learnings file. Agents read their file at startup and update it after completing work:

- **explorer.md** -- Framework navigation strategies, useful search patterns
- **playwright.md** -- Browser exploration patterns, element type handling
- **code-writer.md** -- Code convention patterns, import structures, common mistakes
- **debug.md** -- Failure diagnosis strategies, timeout tuning, selector fix patterns

### What Agents Should Store in Global Memory

After completing work, agents should update global memory with:
- **Framework details**: new action modules, selector files, test directories discovered
- **Patterns**: recurring test patterns, assertion strategies, wait patterns
- **Selector conventions**: data-testid naming patterns, XPath fallback patterns
- **Pitfalls**: things that didn't work, flaky patterns to avoid

### What Agents Should NOT Store in Global Memory

- Ticket-specific details (keep in `memory/tickets/<KEY>/`)
- Temporary state or in-progress data
- Credentials or environment-specific values
