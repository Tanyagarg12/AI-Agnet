# Framework Safety Rules

These rules protect the e2e test framework's core infrastructure from accidental modification.

## NEVER Modify These Files
The following files are critical framework infrastructure. Modifying them affects ALL tests:
- `utils/setHooks.js` — shared test lifecycle hooks
- `utils/setHooksAPI.js` — shared API test lifecycle hooks
- `playwright.config.js` — global Playwright configuration
- `params/global.json` — global timeout parameters
- `utils/generateAccessToken.js` — authentication token generation

If a task seems to require modifying one of these files, STOP and escalate to a human.

## Action Reuse
- ALWAYS check existing actions in `framework/actions/` before creating new action functions
- Prefer importing and reusing existing actions over writing inline page interactions
- Only create a new action file when no existing action covers the required interaction

## Selector Discipline
- Selectors MUST go in `framework/selectors/*.json` as key-value pairs
- NEVER hardcode selectors directly in test files
- Use XPath with `data-testid` as primary strategy
- Support fallbacks via pipe (`|`) separator in selector values

## Code Style (Enforced)
- CommonJS `require()` — no ES module imports
- Double quotes for all strings
- 4-space indentation
- Semicolons required
- No trailing commas
- `printWidth: 80` (Prettier config)

## Test Structure
- Tests run serially — `test.describe.configure({ mode: "serial" })`
- Number tests sequentially: `#1`, `#2`, `#3`
- Use `expect.soft()` for non-blocking assertions
- Use `logger.info()` for structured logging
- Always import hooks from `utils/setHooks.js` (UI) or `utils/setHooksAPI.js` (API)
- **Thin test files**: Test steps MUST be slim (1-5 lines each). ALL business logic, DOM interactions, conditional checks, API calls, hovering, tooltip reading, and multi-step sequences belong in `actions/*.js` as helper functions — NEVER inline in the test file.

## Timeout Rules
- Use `shortTimeout` from `params/global.json` for explicit waits — do NOT multiply timeouts
- WRONG: `{ timeout: mediumTimeout * 1000 }` — this creates excessively long waits
- CORRECT: `{ timeout: shortTimeout }`

## Assertion Error Messages (MANDATORY)
Every `expect()` and `expect.soft()` call MUST include a descriptive error message as the second argument. This makes test failures self-explanatory in logs and traces.

```javascript
// CORRECT — always include error message
expect(row, `Expected row for "${itemName}" to be visible`).toBeVisible();
expect.soft(count, `Issue count mismatch for "${filter}"`).toBe(expectedCount);
expect(currentUrl, `URL should contain "issues-over-time" after navigation`).toContain("issues-over-time");
expect(button, `"Implement Plan" button is not visible`).toBeVisible();

// WRONG — never write bare expects without messages
expect(row).toBeVisible();
expect.soft(count).toBe(expectedCount);
expect(currentUrl).toContain("issues-over-time");
```

This applies to ALL assertion types: `toBeVisible()`, `toContain()`, `toBe()`, `toHaveText()`, `toHaveCount()`, `toBeTruthy()`, etc.

## File Organization
- UI tests: `tests/UI/<feature>/<featureName>.test.js`
- API tests: `tests/api-tests/query-tests/<category>/<queryName>.api.test.js`
- Actions: `actions/<featureName>.js`
- Selectors: `selectors/<featureName>.json`

## Env Files -- NEVER Source in Shell
The framework env files (`env/.env.stg`, `env/.env.dev`, etc.) use colon syntax (`KEY: "value"`), NOT shell `KEY=value` format. They are loaded by `dotenv` via `playwright.config.js`:
```javascript
require("dotenv").config({ path: "env/" + process.env.envFile });
```
- **NEVER** run `source env/.env.stg` or `. env/.env.stg` — will fail with "command not found"
- **NEVER** parse env files with bash to extract values
- To run tests: `envFile=.env.stg npx playwright test ...` — the `envFile` shell var is read by playwright.config.js
- To check env values: read the file content and parse `KEY: "value"` format manually
