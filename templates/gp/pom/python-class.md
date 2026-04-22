# Python Page Object Model Template

Use for Playwright (Python), Selenium (Python), and Appium (Python).

## BasePage (create once per project)

```python
# pages/base_page.py
import json
import os
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.common.by import By

# For Playwright Python, replace with:
# from playwright.sync_api import Page


class BasePage:
    WAIT_TIMEOUT = int(os.getenv('WAIT_TIMEOUT', '10'))

    def __init__(self, driver):
        self.driver = driver
        self.wait = WebDriverWait(driver, self.WAIT_TIMEOUT)

    def navigate_to(self, url: str) -> None:
        self.driver.get(url)

    def click_element(self, xpath: str) -> None:
        element = self.wait.until(
            EC.element_to_be_clickable((By.XPATH, xpath))
        )
        element.click()

    def fill_input(self, xpath: str, value: str) -> None:
        element = self.wait.until(
            EC.visibility_of_element_located((By.XPATH, xpath))
        )
        element.clear()
        element.send_keys(value)

    def get_text(self, xpath: str) -> str:
        element = self.wait.until(
            EC.visibility_of_element_located((By.XPATH, xpath))
        )
        return element.text

    def is_visible(self, xpath: str, timeout: int = 5) -> bool:
        try:
            WebDriverWait(self.driver, timeout).until(
                EC.visibility_of_element_located((By.XPATH, xpath))
            )
            return True
        except Exception:
            return False

    def get_count(self, xpath: str) -> int:
        elements = self.driver.find_elements(By.XPATH, xpath)
        return len(elements)

    def select_option(self, xpath: str, visible_text: str) -> None:
        from selenium.webdriver.support.select import Select
        element = self.wait.until(
            EC.presence_of_element_located((By.XPATH, xpath))
        )
        Select(element).select_by_visible_text(visible_text)

    def take_screenshot(self, name: str) -> None:
        os.makedirs('reports/screenshots', exist_ok=True)
        self.driver.save_screenshot(f'reports/screenshots/{name}.png')

    @staticmethod
    def load_selectors(feature: str) -> dict:
        path = os.path.join('config', 'selectors', f'{feature}.json')
        with open(path) as f:
            return json.load(f)
```

## Feature Page Object (one per page/feature)

```python
# pages/<feature>_page.py
from pages.base_page import BasePage


class <FeatureName>Page(BasePage):
    SELECTORS = BasePage.load_selectors('<feature>')

    def __init__(self, driver):
        super().__init__(driver)

    # Navigation
    def navigate_to(self, base_url: str) -> None:
        super().navigate_to(f"{base_url}/<page-path>")
        # Wait for key element to confirm page loaded
        self.wait.until(lambda d: self.is_visible(self.SELECTORS['mainContainer']))

    # Actions — named after user intent
    def click_<action>(self) -> None:
        self.click_element(self.SELECTORS['<actionElement>'])

    def fill_<field_name>(self, value: str) -> None:
        self.fill_input(self.SELECTORS['<inputElement>'], value)

    def select_<filter_name>(self, value: str) -> None:
        self.click_element(self.SELECTORS['<filterTrigger>'])
        # Click the option
        option_xpath = f"//div[contains(@class,'option') and text()='{value}']"
        self.click_element(option_xpath)

    # Getters — return typed values
    def get_<item_count>(self) -> int:
        text = self.get_text(self.SELECTORS['<counter>'])
        return int(text.strip().replace(',', ''))

    def get_<table_row_count>(self) -> int:
        return self.get_count(self.SELECTORS['<tableRow>'])

    def is_<element>_visible(self) -> bool:
        return self.is_visible(self.SELECTORS['<element>'])
```

## Conftest (fixtures, Selenium/Appium)

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

def load_env_config():
    with open('config/environments.json') as f:
        return json.load(f)[ENV]


@pytest.fixture(scope='session')
def env_config():
    return load_env_config()


@pytest.fixture(scope='session')
def driver():
    options = Options()
    if os.getenv('HEADLESS', 'true').lower() == 'true':
        options.add_argument('--headless=new')
    options.add_argument('--no-sandbox')
    options.add_argument('--disable-dev-shm-usage')
    options.add_argument('--window-size=1920,1080')

    service = Service(ChromeDriverManager().install())
    d = webdriver.Chrome(service=service, options=options)
    d.implicitly_wait(0)  # Use explicit waits only
    yield d
    d.quit()


@pytest.fixture(autouse=True)
def screenshot_on_failure(driver, request):
    yield
    if request.node.rep_call.failed:
        driver.save_screenshot(f'reports/screenshots/FAIL_{request.node.name}.png')
```

## Rules for Generated Classes

1. Load selectors via `BasePage.load_selectors('<feature>')` — never hardcode XPath strings
2. Use `snake_case` for method names: `click_filter_button()`, `get_item_count()`
3. Class names in `PascalCase`: `IssuesPage`, `LoginPage`
4. Type hints on all methods
5. Wrap all waits in BasePage methods — never use `time.sleep()` or raw `driver.find_element`
6. One class per file — file name matches class: `issues_page.py` → `class IssuesPage`
