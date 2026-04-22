# GP Framework Patterns

Accumulated learnings from test framework usage across all GP pipeline runs.
Updated by `gp-learner-agent` after each run.

---

## Playwright (JavaScript / playwright-js)

### Setup
- `npm init playwright@latest` handles everything including browser install
- If using CommonJS: set `"type": "commonjs"` in package.json or use `.cjs` extension
- Chromium installation: `npx playwright install chromium` (only chromium needed for CI)

### Selector Strategies
- `data-testid` is most stable — prefer `[data-testid='x']` or XPath `//[@data-testid='x']`
- Avoid CSS class selectors (`.btn-primary`) — classes change with UI library updates
- For tables: `//*[@data-testid='table']//tbody/tr` + `[position()=N]` for row targeting

### Wait Strategies
- **API-loaded data**: `await page.waitForResponse('**/api/<endpoint>**')` BEFORE asserting content
- **Modal/dialog**: `await page.waitForSelector(selector, { state: 'visible' })`
- **URL change**: `await page.waitForURL(/pattern/)` after navigation actions
- **Network idle**: `await page.waitForLoadState('networkidle')` for complex SPAs

### Common Issues
- `Test timeout exceeded` — page load is slow on staging; increase timeout in playwright.config.js
- `strict mode violation` — selector matches multiple elements; use `.first()` or more specific path
- `context was destroyed` — browser closed before async operation; ensure `afterAll` waits for operations

### Reporting
- HTML report auto-opens by default — set `open: 'never'` in config for CI
- Allure: add `allure-playwright` to reporters array in config

---

## Playwright (Python / playwright-python)

### Setup
- Install order matters: `pip install pytest-playwright` first, then `playwright install chromium`
- Sync API preferred for sequential tests: `from playwright.sync_api import sync_playwright`
- Async API needed for concurrent tests: `from playwright.async_api import async_playwright`

### Key Differences from JS
- No `page.waitForResponse` equivalent — use `page.expect_response('**/api/**')` context manager
- `expect(locator).to_be_visible()` uses pytest-playwright's expect API
- Fixtures in `conftest.py` — `page` and `browser` fixtures provided by pytest-playwright

### Common Issues
- Fixture scope: `scope='function'` for `page`, `scope='session'` for `browser`
- Screenshots: `page.screenshot(path='...')` — path must be created first
- `playwright install` must run after every `pip install playwright` update

---

## Selenium (Python / selenium-python)

### Setup
- `webdriver_manager` handles driver binary — no manual chromedriver download needed
- `implicitly_wait(0)` + explicit waits only — never mix implicit and explicit
- Chrome options: `--headless=new` (modern headless), `--no-sandbox`, `--disable-dev-shm-usage`

### Selector Strategies
- CSS by ID: `By.CSS_SELECTOR, '#element-id'` — most reliable
- XPath: `By.XPATH, '//[@data-testid="x"]'` — good for data-testid
- Avoid: `By.CLASS_NAME` (fragile), `By.TAG_NAME` (too broad)

### Wait Strategies
- `EC.element_to_be_clickable` before clicking
- `EC.visibility_of_element_located` before reading text
- `EC.url_contains('/path')` after navigation actions
- `EC.text_to_be_present_in_element` for dynamic content

### Common Issues
- `StaleElementReferenceException`: Re-find element after page DOM updates; don't save element references
- `ElementNotInteractableException`: Scroll to element first: `driver.execute_script("arguments[0].scrollIntoView()", el)`
- Dropdown handling: Use `Select(element).select_by_visible_text()` for native `<select>` elements

---

## Selenium (Java / selenium-java)

### Setup
- `WebDriverManager.chromedriver().setup()` handles driver — add `io.github.bonigarcia:webdrivermanager` to pom.xml
- TestNG: `@Test`, `@BeforeMethod`, `@AfterMethod` in BaseTest
- Maven Surefire: `<forkCount>1</forkCount>` for stability with WebDriver

### Key Patterns
- Never return `WebElement` from page class public methods — return typed values
- Use `Duration.ofSeconds(N)` with `WebDriverWait` (not deprecated int constructor)
- `@FindBy` annotation (PageFactory) vs constructor pattern — prefer constructor (more explicit)

### Common Issues
- `WebDriverException: chrome not reachable` — driver not in PATH; use WebDriverManager
- `NoSuchSessionException` — driver closed before test; check afterMethod teardown order

---

## Cypress (JavaScript / cypress-js)

### Setup
- `npx cypress open` to verify installation and generate config
- Config: `e2e.specPattern: 'cypress/e2e/**/*.cy.js'`
- Reporter: `mochawesome` for HTML, `@shelex/cypress-allure-plugin` for Allure

### Selector Strategies
- `data-cy` attribute: `cy.get('[data-cy="submit"]')` — Cypress convention
- Chaining: `cy.get('[data-testid="table"]').find('tr').first()`
- Aliases: `cy.get(selector).as('alias')` then `cy.get('@alias')`

### Network Intercept Pattern
```javascript
cy.intercept('GET', '**/api/issues**').as('getIssues');
cy.visit('/issues');
cy.wait('@getIssues');
cy.get('[data-cy="issue-row"]').should('have.length.greaterThan', 0);
```

### Common Issues
- `cy.wait()` with arbitrary timeout — use `cy.wait('@alias')` for network requests instead
- Cross-origin issues: configure `chromeWebSecurity: false` for oauth redirects
- `beforeEach` runs for every test — don't put navigation there if tests are sequential

---

## Appium (Python / appium-python)

### Setup
- Appium server must be running: `appium` (in separate terminal)
- Install drivers: `appium driver install uiautomator2` (Android) or `xcuitest` (iOS)
- Capabilities in `config/capabilities.json` — reference via env var

### Selector Strategies
- Accessibility ID: most portable across Android/iOS
- `By.xpath` with `//android.widget.*` — Android-specific
- `By.xpath` with `//XCUIElement*` — iOS-specific
- Avoid coordinates (`tap_by_coordinates`) — fragile with different screen sizes

### Common Issues
- Session creation fails: Check Appium server is running, device/emulator is connected
- `NoSuchElement` on first launch: App may need cold start; add `app_wait_activity` capability
- Screenshot path: must be writable and exist before calling `driver.save_screenshot()`
