# GP Failure Catalog

Indexed failures and their proven fixes. Consulted by `gp-debugger-agent` before performing live DOM inspection.
Updated after each debug cycle by `gp-learner-agent`.

Format: Each entry has an error pattern, root cause, fix, and reusable lesson.

---

## selector_not_found

### [CATALOG] Playwright | data-testid not found on first render

- **Error Pattern**: `Error: locator.click: Timeout 30000ms exceeded...page.waitForSelector: Timeout...`
- **Root Cause**: React/Vue component renders asynchronously; `data-testid` is not in the initial DOM
- **Fix**: Add `waitForResponse` for the API that populates the component before asserting
  ```javascript
  await page.waitForResponse('**/api/<relevant-endpoint>**');
  await page.click(selectors.targetElement);
  ```
- **Reusable Pattern**: When `data-testid` element is data-driven, ALWAYS wait for its API response before interacting

---

### [CATALOG] Selenium | StaleElementReferenceException after table refresh

- **Error Pattern**: `StaleElementReferenceException: stale element reference: element is not attached to the page`
- **Root Cause**: Element reference saved before action that triggers DOM re-render (filter, sort, search)
- **Fix**: Re-find the element AFTER the action that caused the re-render
  ```python
  self.click_element(self.SELECTORS['filterButton'])
  self.wait.until(EC.staleness_of(old_element))  # wait for re-render
  rows = self.driver.find_elements(By.XPATH, self.SELECTORS['tableRow'])  # re-find
  ```
- **Reusable Pattern**: Never save element references across state changes; always re-find after DOM updates

---

## timeout

### [CATALOG] Playwright | SSO redirect takes longer than default timeout

- **Error Pattern**: `TimeoutError: page.waitForURL: Timeout 30000ms exceeded. Waiting for URL matching /dashboard/`
- **Root Cause**: External SSO provider redirect adds 3-8 seconds beyond Playwright's default expectation
- **Fix**: Use `waitForURL` with explicit timeout increase + `waitForLoadState`
  ```javascript
  await page.waitForURL(/\/dashboard/, { timeout: 60000 });
  await page.waitForLoadState('networkidle');
  ```
- **Reusable Pattern**: After SSO/OAuth redirects, always extend URL wait timeout to 60s+

---

### [CATALOG] Selenium | dynamic dropdown options load via API

- **Error Pattern**: `TimeoutException: Message: ...waiting for element to be clickable...`
- **Root Cause**: Dropdown options are loaded via AJAX after the dropdown opens
- **Fix**: After clicking the dropdown trigger, wait for at least one option to appear before selecting
  ```python
  self.click_element(self.SELECTORS['dropdownTrigger'])
  self.wait.until(EC.presence_of_element_located((By.XPATH, "//div[@role='option']")))
  self.click_element(f"//div[@role='option'][text()='{option_text}']")
  ```
- **Reusable Pattern**: API-loaded dropdowns need two-step wait: trigger open, then wait for options

---

## assertion_failure

### [CATALOG] Playwright | item count assertion fails on first load

- **Error Pattern**: `AssertionError: Expected: 5 Received: 0` — counter shows 0 on initial render
- **Root Cause**: Counter DOM element exists immediately but shows 0 until API data loads
- **Fix**: Wait for API response, then assert
  ```javascript
  await page.waitForResponse('**/api/items**');
  const count = await featurePage.getItemCount();
  expect(count, 'Item count should reflect server data').toBeGreaterThan(0);
  ```
- **Reusable Pattern**: Never assert count/data values immediately after navigation; always wait for API

---

### [CATALOG] Playwright | redirect URL differs between environments

- **Error Pattern**: `Error: page.waitForURL: Timeout...Waiting for URL matching /dashboard`
- **Root Cause**: Staging redirects to `/home` while dev redirects to `/dashboard`
- **Fix**: Use env-specific URL from `config/environments.json`
  ```javascript
  const postLoginUrl = envConfig[ENV].post_login_url || '/dashboard';
  await page.waitForURL(new RegExp(postLoginUrl));
  ```
- **Reusable Pattern**: Never hardcode redirect URLs; always use environment config

---

## syntax_error

### [CATALOG] Python | ModuleNotFoundError for page class

- **Error Pattern**: `ModuleNotFoundError: No module named 'pages.feature_page'`
- **Root Cause**: File created but not in correct directory structure, or `__init__.py` missing
- **Fix**:
  1. Add `__init__.py` to `pages/` directory: `touch pages/__init__.py`
  2. Verify file path matches import: `from pages.feature_page import FeaturePage`
- **Reusable Pattern**: Python projects need `__init__.py` in every package directory

---

### [CATALOG] JavaScript | require() path error for selectors JSON

- **Error Pattern**: `Error: Cannot find module '../config/selectors/feature.json'`
- **Root Cause**: Test file is nested deeper than expected, relative path is wrong
- **Fix**: Use absolute path via `path.join(__dirname, ...)`:
  ```javascript
  const path = require('path');
  const selectors = require(path.join(__dirname, '../../config/selectors/feature.json'));
  ```
- **Reusable Pattern**: Use `path.join(__dirname, ...)` for file paths in CommonJS modules

---

## auth_failure

### [CATALOG] Playwright | Login fails due to CSRF token timing

- **Error Pattern**: `AssertionError: Should redirect to dashboard after login`
- **Root Cause**: Login form submits before CSRF token is populated in the hidden input
- **Fix**: Wait for the network to be idle before filling the form
  ```javascript
  await page.waitForLoadState('networkidle');
  await loginPage.fillCredentials(username, password);
  await loginPage.clickSubmit();
  ```
- **Reusable Pattern**: On login pages with CSRF protection, wait for `networkidle` before interacting with the form

---

## network_error

### [CATALOG] All frameworks | ECONNREFUSED on staging

- **Error Pattern**: `Error: net::ERR_CONNECTION_REFUSED at https://stg.app...`
- **Root Cause**: Staging environment is down or `BASE_URL` env var points to wrong URL
- **Fix**:
  1. Check: `curl -sf ${STAGING_URL}/health` to verify staging is up
  2. If down: skip test run, report environment issue to team
  3. If wrong URL: verify `STAGING_URL` in `.env` file
- **Reusable Pattern**: Always verify environment health before running tests; check URL config first on connection errors
