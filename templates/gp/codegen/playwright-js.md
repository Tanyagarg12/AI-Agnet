# Playwright JavaScript — Test Generation Template

## Conventions

- **Module system**: CommonJS (`require` / `module.exports`)
- **Test structure**: `test.describe.configure({ mode: 'serial', retries: 0 })`
- **Numbered tests**: `#1`, `#2`, `#3`...
- **Assertions**: `expect(value, 'Descriptive message').toBe...` — message is REQUIRED
- **Timeouts**: from `process.env.TEST_TIMEOUT` or `config/environments.json`
- **Selectors**: via `config/selectors/<feature>.json` — NEVER inline
- **Pages**: via `pages/<Feature>Page.js` — NEVER direct `page.click` in test file

## Test File Structure

```javascript
// tests/<feature>/<feature>.spec.js
const { test, expect } = require('@playwright/test');
const { LoginPage } = require('../../pages/LoginPage');
const { <Feature>Page } = require('../../pages/<Feature>Page');

// ── Config from env / environments.json ─────────────────────────────────────
const envConfig = require('../../config/environments.json');
const ENV = process.env.TEST_ENV || 'staging';
const BASE_URL = process.env.BASE_URL || envConfig[ENV].base_url;
const USERNAME = process.env.TEST_USER || envConfig[ENV].username;
const PASSWORD = process.env.TEST_PASSWORD || envConfig[ENV].password;
const TIMEOUT = parseInt(process.env.TEST_TIMEOUT || '30000');

// ── Shared state ─────────────────────────────────────────────────────────────
let page;
let <featurePage>;

test.describe.configure({ mode: 'serial', retries: 0 });
test.setTimeout(TIMEOUT);

// ── Lifecycle hooks ──────────────────────────────────────────────────────────
test.beforeAll(async ({ browser }) => {
    const context = await browser.newContext();
    page = await context.newPage();
    <featurePage> = new <Feature>Page(page);
});

test.afterEach(async ({}, testInfo) => {
    if (testInfo.status !== 'passed') {
        await page.screenshot({
            path: `test-results/FAIL_${testInfo.title.replace(/[^a-z0-9]/gi, '_')}.png`,
            fullPage: true
        });
    }
});

test.afterAll(async () => {
    await page.close();
});

// ── Tests ────────────────────────────────────────────────────────────────────
test('#1 Navigate to app', async () => {
    await page.goto(BASE_URL);
    await expect(page, 'App should load at the base URL').toHaveURL(new RegExp(BASE_URL));
});

test('#2 Login', async () => {
    const loginPage = new LoginPage(page);
    await loginPage.login(USERNAME, PASSWORD);
    await expect(page, 'Should redirect to dashboard after successful login')
        .toHaveURL(new RegExp('/dashboard'));
});

test('#3 Navigate to <feature>', async () => {
    await <featurePage>.navigateTo(BASE_URL);
    const isVisible = await <featurePage>.is<MainElement>Visible();
    expect(isVisible, '<Feature> main container should be visible after navigation').toBe(true);
});

test('#4 <Scenario from AC>', async () => {
    // Arrange
    await <featurePage>.navigateTo(BASE_URL);

    // Act
    await <featurePage>.click<Action>();

    // Assert — EVERY expect MUST have a message
    const result = await <featurePage>.get<Result>();
    expect(result, '<Expected outcome per acceptance criterion>').toBe(<expectedValue>);
});

// Edge case
test('#5 <Edge case scenario>', async () => {
    await <featurePage>.navigateTo(BASE_URL);
    await <featurePage>.select<Filter>('NonExistentValue');
    const count = await <featurePage>.get<ItemCount>();
    expect(count, 'Filter with no matches should show 0 items').toBe(0);
    const isEmpty = await <featurePage>.is<EmptyState>Visible();
    expect(isEmpty, 'Empty state message should appear when no results').toBe(true);
});
```

## playwright.config.js Template

```javascript
// playwright.config.js
const { defineConfig, devices } = require('@playwright/test');

module.exports = defineConfig({
    testDir: './tests',
    timeout: parseInt(process.env.TEST_TIMEOUT || '30000'),
    retries: 0,
    workers: 1,
    reporter: [
        ['junit', { outputFile: 'test-results/results.xml' }],
        ['html', { outputFolder: 'playwright-report', open: 'never' }],
    ],
    use: {
        headless: process.env.HEADLESS !== 'false',
        viewport: { width: 1920, height: 1080 },
        screenshot: 'only-on-failure',
        video: 'retain-on-failure',
        trace: 'retain-on-failure',
        baseURL: process.env.BASE_URL,
    },
    projects: [
        { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    ],
});
```

## Key Patterns

### Wait for API response before assertion
```javascript
// Pattern: data loads from API — wait before asserting
await page.waitForResponse('**/api/issues**');
const count = await featurePage.getIssueCount();
expect(count, 'Issue count should update after API response').toBeGreaterThan(0);
```

### Wait for element after navigation
```javascript
// Pattern: after click, wait for result before asserting
await featurePage.clickFilterButton();
await page.waitForSelector(selectors.filteredResults, { state: 'visible' });
```

### Verify URL change
```javascript
// Pattern: action causes navigation
await featurePage.clickCreateButton();
await expect(page, 'Should navigate to create page').toHaveURL(/\/create/);
```

### Soft assertions for non-blocking checks
```javascript
// Pattern: multiple assertions where one failure shouldn't stop others
expect.soft(item.name, 'Item name should be non-empty').toBeTruthy();
expect.soft(item.status, 'Item status should be Active').toBe('Active');
// Hard assertion at end
expect(page, 'Page should still be on expected URL').toHaveURL(/\/items/);
```

## Anti-Patterns to AVOID

```javascript
// ❌ WRONG — inline selector
await page.click("[data-testid='filter-btn']");

// ✅ CORRECT — via POM method
await featurePage.clickFilterButton();

// ❌ WRONG — no assertion message
expect(count).toBe(5);

// ✅ CORRECT — with message
expect(count, 'Filtered results should show exactly 5 Critical items').toBe(5);

// ❌ WRONG — hardcoded URL
await page.goto('https://staging.myapp.com/issues');

// ✅ CORRECT — from config
await featurePage.navigateTo(BASE_URL);

// ❌ WRONG — sleep
await page.waitForTimeout(3000);

// ✅ CORRECT — wait for specific condition
await page.waitForResponse('**/api/data**');
```
