# Selenium Python — Test Generation Template

## Conventions

- **Test runner**: pytest
- **Assertion style**: `assert value == expected, "message"`
- **Naming**: `snake_case` for functions, `PascalCase` for classes
- **Waits**: always `WebDriverWait` / `ExpectedConditions` — never `time.sleep()`
- **Selectors**: via `config/selectors/<feature>.json` loaded in page class
- **Fixtures**: in `conftest.py` — driver, env_config
- **Page Objects**: extend `BasePage`, one class per page

## Test File Structure

```python
# tests/test_<feature>.py
import pytest
import json
import os
from pages.<feature>_page import <Feature>Page
from pages.login_page import LoginPage

ENV = os.getenv('TEST_ENV', 'staging')


class Test<Feature>:
    """Tests for <TICKET_ID>: <TICKET_TITLE>"""

    def test_navigate_to_<feature>(self, driver, env_config):
        """AC: <acceptance criterion>"""
        # Arrange
        base_url = os.getenv('BASE_URL', env_config['base_url'])

        # Act
        <feature>_page = <Feature>Page(driver)
        <feature>_page.navigate_to(base_url)

        # Assert
        assert <feature>_page.is_<element>_visible(), \
            "<Feature> main container should be visible after navigation"

    def test_<scenario_name>(self, driver, env_config):
        """AC: <acceptance criterion>"""
        base_url = os.getenv('BASE_URL', env_config['base_url'])
        <feature>_page = <Feature>Page(driver)
        <feature>_page.navigate_to(base_url)

        # Act
        <feature>_page.click_<action>()

        # Assert
        result = <feature>_page.get_<result>()
        assert result == <expected_value>, \
            f"<Expected outcome per AC>. Got: {result}"

    def test_<edge_case>(self, driver, env_config):
        """Edge case: <description>"""
        base_url = os.getenv('BASE_URL', env_config['base_url'])
        <feature>_page = <Feature>Page(driver)
        <feature>_page.navigate_to(base_url)

        <feature>_page.select_<filter>('NonExistentValue')
        count = <feature>_page.get_<item_count>()
        assert count == 0, \
            f"Filter with no matches should show 0 items, got {count}"
        assert <feature>_page.is_empty_state_visible(), \
            "Empty state message should appear when no results found"
```

## pytest.ini

```ini
[pytest]
testpaths = tests
addopts = -v --tb=short --junitxml=results.xml
log_cli = true
log_cli_level = INFO
```

## conftest.py

```python
# conftest.py
import pytest
import json
import os
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from webdriver_manager.chrome import ChromeDriverManager


ENV = os.getenv('TEST_ENV', 'staging')


@pytest.fixture(scope='session')
def env_config():
    with open('config/environments.json') as f:
        return json.load(f)[ENV]


@pytest.fixture(scope='function')
def driver():
    options = Options()
    if os.getenv('HEADLESS', 'true').lower() != 'false':
        options.add_argument('--headless=new')
    options.add_argument('--no-sandbox')
    options.add_argument('--disable-dev-shm-usage')
    options.add_argument('--window-size=1920,1080')

    service = Service(ChromeDriverManager().install())
    d = webdriver.Chrome(service=service, options=options)
    d.implicitly_wait(0)  # Use explicit waits only
    yield d
    d.quit()


@pytest.hookimpl(tryfirst=True, hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    rep = outcome.get_result()
    setattr(item, 'rep_' + rep.when, rep)


@pytest.fixture(autouse=True)
def screenshot_on_failure(driver, request):
    yield
    if hasattr(request.node, 'rep_call') and request.node.rep_call.failed:
        os.makedirs('reports/screenshots', exist_ok=True)
        safe_name = request.node.name.replace('/', '_')
        driver.save_screenshot(f'reports/screenshots/FAIL_{safe_name}.png')
```

## Key Patterns

### Wait for element to be clickable
```python
# In BasePage
def click_element(self, xpath: str) -> None:
    element = self.wait.until(EC.element_to_be_clickable((By.XPATH, xpath)))
    element.click()
```

### Wait for text to appear
```python
# In page class
def wait_for_success_message(self, expected_text: str) -> None:
    self.wait.until(
        EC.text_to_be_present_in_element(
            (By.XPATH, self.SELECTORS['successMessage']),
            expected_text
        )
    )
```

### Verify table row content
```python
def get_row_data(self, row_index: int) -> dict:
    rows = self.driver.find_elements(By.XPATH, self.SELECTORS['tableRow'])
    if row_index >= len(rows):
        return {}
    cells = rows[row_index].find_elements(By.TAG_NAME, 'td')
    return {'name': cells[0].text, 'status': cells[1].text}
```

## Anti-Patterns to AVOID

```python
# ❌ WRONG — hardcoded selector in test
driver.find_element(By.XPATH, "//button[@id='filter-btn']").click()

# ✅ CORRECT — via page method
feature_page.click_filter_button()

# ❌ WRONG — sleep
import time; time.sleep(3)

# ✅ CORRECT — explicit wait
self.wait.until(EC.visibility_of_element_located((By.XPATH, xpath)))

# ❌ WRONG — no assertion message
assert count == 5

# ✅ CORRECT — with message
assert count == 5, f"Expected 5 Critical items after filter, got {count}"
```
