# E2E Test File Scaffold

Template for creating a Playwright test file following framework conventions.

## File Location

`framework/tests/UI/<feature_area>/<testName>/<testName>.test.js`

## Template

```javascript
const { test, expect } = require("@playwright/test");
const {
    setBeforeAll,
    setBeforeEach,
    setAfterEach,
    setAfterAll
} = require("../../../utils/setHooks");
const logger = require("../../../logging");
const { navigation } = require("../../../actions/general");
const {
    verifyLoginPage,
    closeWhatsNew
} = require("../../../actions/login");
// Import feature-specific actions
// const { <action1>, <action2> } = require("../../../actions/<feature>");

let testName = "<testName>";
let orgName = process.env.SANITY_ORG_NAME;
let userName = process.env.SANITY_USER;
let userPassword = process.env.USER_PASSWORD;
let url = process.env.LOGIN_URL;
let acceptedUrl = process.env.POST_LOGIN_URL;
let environment = process.env.ENVIRONMENT;
let testTimeOut = parseInt(process.env.TEST_TIMEOUT);
let page, context;

test.describe.configure({ mode: "serial", retries: 0 });
test.setTimeout(testTimeOut);

test.beforeAll(async ({}) => {
    ({ page, context } = await setBeforeAll(
        testName,
        userName,
        orgName,
        url,
        environment,
        false
    ));
});

test.beforeEach(async ({}, testInfo) => {
    await setBeforeEach(testInfo);
});

test.afterEach(async ({}, testInfo) => {
    await setAfterEach(testInfo, orgName);
});

test.afterAll(async ({}, testInfo) => {
    await setAfterAll(testInfo, environment, testName, orgName);
});

test("#1 Navigate to homepage", async () => {
    await navigation(page, url);
});

test("#2 Login", async () => {
    await verifyLoginPage(page, userName, userPassword, acceptedUrl);
    await closeWhatsNew(page);
});

// Add feature-specific tests below, numbered sequentially

test("#3 <Test description>", async () => {
    // Navigate to target page
    // Perform actions
    // Assert results
});
```

## Conventions Checklist

Before writing a test, verify:

- [ ] CommonJS `require()` -- no ES module `import`
- [ ] Double quotes for strings
- [ ] 4-space indentation
- [ ] Semicolons at end of statements
- [ ] No trailing commas in objects/arrays
- [ ] `test.describe.configure({ mode: "serial", retries: 0 })`
- [ ] `test.setTimeout(testTimeOut)` using env variable
- [ ] `setBeforeAll` with correct parameter order: testName, userName, orgName, url, environment, false
- [ ] Tests numbered sequentially: `#1`, `#2`, `#3`, etc.
- [ ] Test #1 is always navigation, #2 is always login
- [ ] `logger.info()` for structured logging (not console.log)
- [ ] `expect.soft()` for non-blocking assertions in multi-property checks
- [ ] Action functions imported from `framework/actions/` -- not inline page calls
- [ ] Selectors from JSON files in `framework/selectors/` -- not hardcoded in tests
- [ ] Test steps are slim (1-5 lines each) -- all logic lives in action functions
- [ ] Use `shortTimeout` from `params/global.json` -- never multiply timeouts (e.g. `mediumTimeout * 1000` is WRONG)

## Action Function Pattern

```javascript
// framework/actions/<feature>.js
const selectors = require("../selectors/<feature>.json");
const { shortTimeout } = require("../params/global.json");

async function verifyFeatureElement(page) {
    const element = page.locator(selectors.elementKey);
    await element.waitFor({ timeout: shortTimeout });
    await expect(element).toBeVisible();
}

module.exports = {
    verifyFeatureElement
};
```

## Selector File Pattern

```json
{
    "elementKey": "//*[@data-testid='element-id'] | //fallback/xpath",
    "buttonKey": "//*[@data-testid='button-id']",
    "tableRow": "//tr[contains(@class, 'row')]"
}
```

Use XPath with pipe (`|`) fallbacks. Prefer `data-testid` attributes as the primary locator strategy.
