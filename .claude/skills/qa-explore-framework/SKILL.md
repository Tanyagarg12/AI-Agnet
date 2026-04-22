---
name: qa-explore-framework
description: Explore the E2E framework to find relevant patterns, actions, selectors, and similar tests for a given ticket. No team needed -- the lead performs exploration directly.
disable-model-invocation: true
argument-hint: "[ticket-key]"
---

# Explore E2E Framework

Analyze the E2E test framework to find relevant patterns, reusable components, and similar tests for a Jira ticket.

## Usage

```
/qa-explore-framework OXDEV-123
```

## Prerequisites

- `memory/tickets/$ARGUMENTS/triage.json` must exist (run `/qa-triage-ticket` first)
- The `framework/` directory must be accessible (via CLAUDE_CODE_ADDITIONAL_DIRECTORIES)

## Process

### Step 1: Load Context

1. Read `memory/tickets/$ARGUMENTS/triage.json` for feature area, test type, and target pages
2. Read `memory/framework-catalog.md` for framework overview
3. Read `memory/test-patterns.md` for known test patterns (if exists)

### Step 1b: Write Skeleton Output (BEFORE any research)

Write a skeleton `memory/tickets/$ARGUMENTS/exploration.md` immediately:

```markdown
# Framework Exploration: $ARGUMENTS

## Similar Tests Found
(searching...)

## Reusable Actions
(searching...)

## Existing Selectors
(searching...)

## Missing Pieces
(pending exploration)

## Playwright Exploration Prompt
(pending)
```

This ensures output exists even if you run out of turns. UPDATE this file as you discover things.

### Step 2: Find Similar Tests

Search `framework/tests/UI/<feature_area>/` for existing tests that cover similar functionality:

```bash
# List all test files in the feature area
ls framework/tests/UI/<feature_area>/

# Search for tests matching keywords from the ticket summary
grep -rl "<keyword>" framework/tests/UI/
```

For each similar test found:
- Read the test file structure (imports, hooks, test steps)
- Note which actions and selectors it uses
- Note the environment variables it references
- Note any special patterns (conditional execution, data setup)

### Step 3: Find Relevant Actions

Search `framework/actions/` for action modules related to the feature area:

```bash
# Find action files by feature area
ls framework/actions/<feature_area>*.js
grep -rl "<feature_keyword>" framework/actions/
```

For each relevant action module:
- List all exported functions
- Note function signatures (parameters)
- Identify which functions can be reused for the new test

### Step 4: Find Relevant Selectors

Search `framework/selectors/` for selector files related to the feature area:

```bash
ls framework/selectors/<feature_area>*.json
grep -rl "<element_keyword>" framework/selectors/
```

For each relevant selector file:
- List all selector keys
- Note selector patterns (XPath, data-testid, pipe fallbacks)
- Identify which selectors can be reused

### Step 5: Check Environment Configuration

Read the relevant environment files:
- `framework/env/.env.dev` (or whichever env the test targets)
- **WARNING**: Env files use colon syntax (`KEY: "value"`), NOT shell format. Do NOT try to `source` them — read the file content directly.
- Note required environment variables: SANITY_ORG_NAME, SANITY_USER, USER_PASSWORD, LOGIN_URL, etc.
- Verify the test org has the necessary data for the feature being tested

### Step 6: Study Framework Patterns

Analyze the common patterns used across the framework:
- **Login flow**: how tests handle authentication (verifyLoginPage, closeWhatsNew)
- **Navigation**: how tests navigate to pages (navigation action, direct URL)
- **Assertions**: common assertion patterns (expect vs expect.soft)
- **Waits**: how tests handle loading states (waitForSelector, custom waits)
- **Data setup**: how tests prepare test data (API calls, fixture files)

### Step 7: Write Exploration Output

Write structured JSON to `memory/tickets/$ARGUMENTS/explorer-output.json` (REQUIRED — dashboard depends on this):
```json
{
    "similar_tests": [{ "file": "<path>", "feature": "<area>", "relevance": "<why>" }],
    "reusable_actions": [{ "file": "<path>", "functions": ["<func1>", "<func2>"] }],
    "reusable_selectors": [{ "file": "<path>", "count": 12, "keys": ["<key1>"] }],
    "new_actions_needed": ["<action1>", "<action2>"],
    "new_selectors_needed": ["<selector1>", "<selector2>"],
    "needs_baseline": false
}
```

Also write findings to `memory/tickets/$ARGUMENTS/exploration.md`:

```markdown
# Framework Exploration: $ARGUMENTS

## Similar Tests Found
| Test File | Feature | Relevance |
|-----------|---------|-----------|
| <path> | <what it tests> | <why relevant> |

## Reusable Actions
| Module | Function | Purpose |
|--------|----------|---------|
| actions/<module>.js | <function> | <what it does> |

## Reusable Selectors
| File | Key | Selector |
|------|-----|----------|
| selectors/<file>.json | <key> | <selector value> |

## Environment Variables Required
- SANITY_ORG_NAME: <value>
- SANITY_USER: <value>
- LOGIN_URL: <value>
- POST_LOGIN_URL: <value>
- ENVIRONMENT: <value>
- TEST_TIMEOUT: <value>

## Test Pattern to Follow
<describe the recommended pattern based on similar tests>

## New Actions Needed
<list actions that need to be created>

## New Selectors Needed
<list selectors that need to be added>
```

### Step 8: Update Checkpoint

Update `memory/tickets/$ARGUMENTS/checkpoint.json`:
- Add "explorer" to `completed_stages`
- Set `current_stage` to "playwright"
- Add `stage_outputs.explorer: "memory/tickets/$ARGUMENTS/exploration.md"`

### Step 9: Append Audit Log

Append to `memory/tickets/$ARGUMENTS/audit.md`:
```
### [<ISO-8601>] explorer-agent
**Action**: Explore framework for $ARGUMENTS
**Target**: memory/tickets/$ARGUMENTS/exploration.md
**Result**: Found <N> similar tests, <N> reusable actions, <N> reusable selectors
**Details**: Feature area: <area>, pattern: <recommended pattern>
```

### Step 10: Report to Dashboard

**DASHBOARD REPORT (MANDATORY)** — execute this bash command:
```bash
./scripts/report-to-dashboard.sh $ARGUMENTS explorer --status completed
```

## Arguments

- `$ARGUMENTS` -- the Jira ticket key (e.g., OXDEV-123)
