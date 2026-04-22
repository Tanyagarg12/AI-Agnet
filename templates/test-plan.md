# Test Structure Plan

Template for planning the test file structure before implementation.

## Test Plan: <TICKET-KEY>

### Test File
- **Path**: `framework/tests/UI/<feature_area>/<testName>/<testName>.test.js`
- **Test name**: `<testName>`
- **Serial mode**: yes
- **Timeout**: `parseInt(process.env.TEST_TIMEOUT)`

### Environment
- **Environment file**: `.env.<env>`
- **Org**: `process.env.SANITY_ORG_NAME`
- **User**: `process.env.SANITY_USER`

### Test Steps (sequential)

| # | Test Title | Action Functions | Assertions |
|---|-----------|-----------------|------------|
| 1 | Navigate to homepage | `navigation(page, url)` | Page loads |
| 2 | Login | `verifyLoginPage()`, `closeWhatsNew()` | Login successful |
| 3 | Navigate to <page> | `navigation(page, targetUrl)` | Page visible |
| 4 | <Action description> | `<actionFunction>(page, ...)` | `expect(...)` |
| ... | ... | ... | ... |

### Actions Needed

| Module | Function | New/Existing | Description |
|--------|----------|-------------|-------------|
| `actions/general.js` | `navigation` | existing | Navigate to URL |
| `actions/login.js` | `verifyLoginPage` | existing | Login flow |
| `actions/login.js` | `closeWhatsNew` | existing | Close what's new dialog |
| `actions/<feature>.js` | `<newFunction>` | new | <description> |

### Selectors Needed

| File | Key | Selector | New/Existing |
|------|-----|----------|-------------|
| `selectors/<feature>.json` | `<key>` | `<xpath or data-testid>` | new |
| `selectors/<existing>.json` | `<key>` | `<value>` | existing (reuse) |

### Dependencies
- Requires org `<name>` to have `<data/feature>` configured
- Requires environment `<env>` with `<specific config>`
- Baseline data: <yes/no -- what data must exist>

### Risk Areas
- <potential flakiness sources>
- <environment-specific behavior>
- <timing-sensitive elements>
