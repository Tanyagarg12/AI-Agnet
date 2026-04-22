#!/bin/bash
# GP Test Agent -- Setup Script
# Sets up a test automation project from scratch or verifies an existing one.
#
# Usage:
#   ./scripts/setup.sh

set -e

IS_WINDOWS=false
IS_MINGW=false
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true; IS_MINGW=true ;;
  *Microsoft*|*WSL*)     IS_WINDOWS=true ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

normalize_path() {
  echo "$1" | sed 's|\\|/|g'
}

echo "============================================"
echo "  GP Test Agent -- Setup"
echo "============================================"
echo ""

# ── [1/4] Prerequisites ──────────────────────────────────────────────────────

echo "[1/4] Checking prerequisites..."

MISSING=()
command -v claude &>/dev/null || MISSING+=("claude  →  npm install -g @anthropic-ai/claude-code")
command -v node   &>/dev/null || MISSING+=("node    →  https://nodejs.org")
command -v npx    &>/dev/null || MISSING+=("npx     →  comes with Node.js")
command -v git    &>/dev/null || MISSING+=("git     →  https://git-scm.com/download/win")
command -v jq     &>/dev/null || MISSING+=("jq      →  scoop install jq  /  choco install jq")

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "  Missing required tools:"
  for tool in "${MISSING[@]}"; do echo "    - $tool"; done
  echo ""
  echo "  Install them and re-run this script."
  exit 1
fi
echo "  All prerequisites found."
echo ""

# ── [2/4] Framework & Project Setup ─────────────────────────────────────────

echo "[2/4] Test automation framework setup..."
echo ""

# Step A: Choose framework
echo "  What testing framework do you want to use?"
echo ""
echo "    1)  Playwright (JavaScript)        [playwright-js]"
echo "    2)  Playwright (TypeScript)        [playwright-typescript]"
echo "    3)  Playwright (Python)            [playwright-python]"
echo "    4)  Selenium   (Python)            [selenium-python]"
echo "    5)  Selenium   (Java + TestNG)     [selenium-java]"
echo "    6)  Cypress    (JavaScript)        [cypress-js]"
echo "    7)  Appium     (Python) — Mobile   [appium-python]"
echo "    8)  Appium     (Java)   — Mobile   [appium-java]"
echo "    9)  Robot Framework                [robot-framework]"
echo ""
read -rp "  Enter number (1-9): " FW_CHOICE

case "$FW_CHOICE" in
  1) FRAMEWORK="playwright-js";      LANG="javascript"; FW_LABEL="Playwright (JavaScript)" ;;
  2) FRAMEWORK="playwright-typescript"; LANG="typescript"; FW_LABEL="Playwright (TypeScript)" ;;
  3) FRAMEWORK="playwright-python";  LANG="python";     FW_LABEL="Playwright (Python)"    ;;
  4) FRAMEWORK="selenium-python";    LANG="python";     FW_LABEL="Selenium (Python)"      ;;
  5) FRAMEWORK="selenium-java";      LANG="java";       FW_LABEL="Selenium (Java)"        ;;
  6) FRAMEWORK="cypress-js";         LANG="javascript"; FW_LABEL="Cypress (JavaScript)"   ;;
  7) FRAMEWORK="appium-python";      LANG="python";     FW_LABEL="Appium (Python)"        ;;
  8) FRAMEWORK="appium-java";        LANG="java";       FW_LABEL="Appium (Java)"          ;;
  9) FRAMEWORK="robot-framework";    LANG="python";     FW_LABEL="Robot Framework"        ;;
  *)
    echo "  Invalid choice. Defaulting to Playwright (JavaScript)."
    FRAMEWORK="playwright-js"; LANG="javascript"; FW_LABEL="Playwright (JavaScript)"
    ;;
esac

echo ""
echo "  Selected: $FW_LABEL"
echo ""

# Step B: Project folder
echo "  Enter the path for your test project folder."
if [ "$IS_WINDOWS" = true ]; then
  echo "  Example: C:/Users/yourname/Desktop/my-tests"
  echo "           (forward or back slashes both work)"
else
  echo "  Example: /home/yourname/projects/my-tests"
fi
echo "  (If the folder already contains your test code, just type its path — we will only check dependencies)"
echo ""
read -rp "  Project folder path: " PROJECT_PATH_RAW

# Trim leading/trailing whitespace and quotes
PROJECT_PATH_RAW=$(echo "$PROJECT_PATH_RAW" | sed 's/^[[:space:]"]*//;s/[[:space:]"]*$//')
PROJECT_PATH="$(normalize_path "$PROJECT_PATH_RAW")"

if [ -z "$PROJECT_PATH" ]; then
  echo "  No path provided. Aborting."
  exit 1
fi

echo ""

# Step C: Create from scratch OR verify existing
if [ -d "$PROJECT_PATH" ]; then
  # Folder exists — detect if it has code
  HAS_CODE=false
  [ -f "$PROJECT_PATH/package.json" ]      && HAS_CODE=true
  [ -f "$PROJECT_PATH/pom.xml" ]           && HAS_CODE=true
  [ -f "$PROJECT_PATH/requirements.txt" ]  && HAS_CODE=true
  [ -f "$PROJECT_PATH/Pipfile" ]           && HAS_CODE=true
  [ -f "$PROJECT_PATH/pyproject.toml" ]    && HAS_CODE=true
  [ -f "$PROJECT_PATH/build.gradle" ]      && HAS_CODE=true

  if [ "$HAS_CODE" = true ]; then
    echo "  Existing project detected at: $PROJECT_PATH"
    echo "  Checking dependencies only (not overwriting your code)..."
    echo ""
    EXISTING_PROJECT=true
  else
    echo "  Folder exists but is empty — creating project from scratch..."
    EXISTING_PROJECT=false
  fi
else
  echo "  Creating new project at: $PROJECT_PATH"
  mkdir -p "$PROJECT_PATH"
  EXISTING_PROJECT=false
fi

# Step D: Scaffold new project if needed
if [ "$EXISTING_PROJECT" = false ]; then
  echo ""
  echo "  Scaffolding $FW_LABEL project structure..."

  # Common directories
  mkdir -p "$PROJECT_PATH/tests"
  mkdir -p "$PROJECT_PATH/pages"
  mkdir -p "$PROJECT_PATH/helpers"
  mkdir -p "$PROJECT_PATH/config/selectors"
  mkdir -p "$PROJECT_PATH/fixtures"
  mkdir -p "$PROJECT_PATH/reports"

  # Framework-specific extras
  case "$FRAMEWORK" in
    appium-python|appium-java)
      mkdir -p "$PROJECT_PATH/screens"  ;;
    selenium-java|appium-java)
      PROJECT_NAME=$(basename "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
      mkdir -p "$PROJECT_PATH/src/test/java/com/tests/pages"
      mkdir -p "$PROJECT_PATH/src/test/java/com/tests/tests"
      mkdir -p "$PROJECT_PATH/src/test/java/com/tests/utils"
      mkdir -p "$PROJECT_PATH/src/test/resources" ;;
    robot-framework)
      mkdir -p "$PROJECT_PATH/resources/keywords"
      mkdir -p "$PROJECT_PATH/resources/pages" ;;
  esac

  # .gitignore
  cat > "$PROJECT_PATH/.gitignore" <<'GITEOF'
node_modules/
__pycache__/
*.pyc
.pytest_cache/
target/
.env
allure-results/
allure-report/
playwright-report/
test-results/
reports/
*.log
GITEOF

  # environments.json — template only, no real credentials
  cat > "$PROJECT_PATH/config/environments.json" <<'ENVJSON'
{
  "staging": {
    "base_url": "${STAGING_URL}",
    "username": "${TEST_USER}",
    "password": "${TEST_PASSWORD}"
  },
  "dev": {
    "base_url": "${DEV_URL}",
    "username": "${DEV_USER}",
    "password": "${DEV_PASSWORD}"
  }
}
ENVJSON

  # selectors template
  cat > "$PROJECT_PATH/config/selectors/example.json" <<'SELECTORS'
{
  "_comment": "Add selectors per feature. Use XPath with | pipe for fallbacks.",
  "loginButton": "//button[@data-testid='login-btn'] | //button[text()='Login']",
  "emailInput": "//input[@type='email'] | //input[@name='email']"
}
SELECTORS

  # .env.example
  cat > "$PROJECT_PATH/.env.example" <<'DOTENV'
# Copy this to .env and fill in your values
STAGING_URL=https://staging.yourapp.com
TEST_USER=automation@yourapp.com
TEST_PASSWORD=your-password
DEV_URL=https://dev.yourapp.com
TEST_ENV=staging
HEADLESS=true
TEST_TIMEOUT=30000
DOTENV

  # Framework-specific config & base files
  case "$FRAMEWORK" in

    playwright-js)
      cat > "$PROJECT_PATH/package.json" <<'PKG'
{
  "name": "test-automation",
  "version": "1.0.0",
  "scripts": {
    "test": "npx playwright test",
    "test:report": "npx playwright test --reporter=html",
    "report": "npx playwright show-report"
  },
  "devDependencies": {
    "@playwright/test": "latest"
  }
}
PKG
      cat > "$PROJECT_PATH/playwright.config.js" <<'PWCONF'
const { defineConfig, devices } = require('@playwright/test');
require('dotenv').config();

module.exports = defineConfig({
  testDir: './tests',
  timeout: parseInt(process.env.TEST_TIMEOUT || '30000'),
  retries: 0,
  workers: 1,
  reporter: [
    ['html', { outputFolder: 'playwright-report', open: 'never' }],
    ['junit', { outputFile: 'test-results/results.xml' }],
  ],
  use: {
    headless: process.env.HEADLESS !== 'false',
    viewport: { width: 1920, height: 1080 },
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  ],
});
PWCONF
      cat > "$PROJECT_PATH/pages/BasePage.js" <<'BASEPAGE'
// Base Page Object — extend this for every page
class BasePage {
  constructor(page) {
    this.page = page;
  }
  async navigateTo(url) {
    await this.page.goto(url, { waitUntil: 'networkidle' });
  }
  async clickElement(selector) {
    await this.page.waitForSelector(selector, { state: 'visible' });
    await this.page.click(selector);
  }
  async fillInput(selector, value) {
    await this.page.waitForSelector(selector, { state: 'visible' });
    await this.page.fill(selector, value);
  }
  async getText(selector) {
    await this.page.waitForSelector(selector, { state: 'visible' });
    return await this.page.textContent(selector);
  }
  async isVisible(selector, timeout = 5000) {
    try {
      await this.page.waitForSelector(selector, { state: 'visible', timeout });
      return true;
    } catch { return false; }
  }
}
module.exports = { BasePage };
BASEPAGE
      ;;

    playwright-typescript)
      cat > "$PROJECT_PATH/package.json" <<'PKG'
{
  "name": "test-automation",
  "version": "1.0.0",
  "scripts": {
    "test": "npx playwright test",
    "test:report": "npx playwright test --reporter=html"
  },
  "devDependencies": {
    "@playwright/test": "latest",
    "typescript": "latest",
    "@types/node": "latest"
  }
}
PKG
      cat > "$PROJECT_PATH/playwright.config.ts" <<'PWCONF'
import { defineConfig, devices } from '@playwright/test';
import dotenv from 'dotenv';
dotenv.config();

export default defineConfig({
  testDir: './tests',
  timeout: parseInt(process.env.TEST_TIMEOUT || '30000'),
  retries: 0,
  workers: 1,
  reporter: [['html', { open: 'never' }], ['junit', { outputFile: 'test-results/results.xml' }]],
  use: {
    headless: process.env.HEADLESS !== 'false',
    viewport: { width: 1920, height: 1080 },
    screenshot: 'only-on-failure',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
PWCONF
      cat > "$PROJECT_PATH/tsconfig.json" <<'TSCONFIG'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "strict": true,
    "esModuleInterop": true
  }
}
TSCONFIG
      ;;

    playwright-python)
      cat > "$PROJECT_PATH/requirements.txt" <<'REQ'
pytest-playwright
pytest
allure-pytest
pytest-html
REQ
      cat > "$PROJECT_PATH/pytest.ini" <<'PYTESTINI'
[pytest]
testpaths = tests
addopts = -v --tb=short --junitxml=test-results/results.xml
PYTESTINI
      cat > "$PROJECT_PATH/conftest.py" <<'CONF'
import pytest
import json, os

ENV = os.getenv('TEST_ENV', 'staging')

@pytest.fixture(scope='session')
def env_config():
    with open('config/environments.json') as f:
        return json.load(f)[ENV]

@pytest.fixture(scope='session')
def base_url(env_config):
    return os.getenv('STAGING_URL', env_config['base_url'])
CONF
      ;;

    selenium-python)
      cat > "$PROJECT_PATH/requirements.txt" <<'REQ'
selenium
pytest
pytest-html
allure-pytest
webdriver-manager
python-dotenv
REQ
      cat > "$PROJECT_PATH/pytest.ini" <<'PYTESTINI'
[pytest]
testpaths = tests
addopts = -v --tb=short --junitxml=test-results/results.xml
PYTESTINI
      cat > "$PROJECT_PATH/conftest.py" <<'CONF'
import pytest, json, os
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
    d = webdriver.Chrome(service=Service(ChromeDriverManager().install()), options=options)
    d.implicitly_wait(0)
    yield d
    d.quit()
CONF
      cat > "$PROJECT_PATH/pages/base_page.py" <<'BASEPAGE'
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.common.by import By
import json, os

class BasePage:
    WAIT_TIMEOUT = int(os.getenv('WAIT_TIMEOUT', '10'))

    def __init__(self, driver):
        self.driver = driver
        self.wait = WebDriverWait(driver, self.WAIT_TIMEOUT)

    def navigate_to(self, url):
        self.driver.get(url)

    def click_element(self, xpath):
        self.wait.until(EC.element_to_be_clickable((By.XPATH, xpath))).click()

    def fill_input(self, xpath, value):
        el = self.wait.until(EC.visibility_of_element_located((By.XPATH, xpath)))
        el.clear(); el.send_keys(value)

    def get_text(self, xpath):
        return self.wait.until(EC.visibility_of_element_located((By.XPATH, xpath))).text

    def is_visible(self, xpath, timeout=5):
        try:
            WebDriverWait(self.driver, timeout).until(EC.visibility_of_element_located((By.XPATH, xpath)))
            return True
        except: return False

    @staticmethod
    def load_selectors(feature):
        with open(f'config/selectors/{feature}.json') as f:
            return json.load(f)
BASEPAGE
      ;;

    cypress-js)
      cat > "$PROJECT_PATH/package.json" <<'PKG'
{
  "name": "test-automation",
  "version": "1.0.0",
  "scripts": {
    "test": "npx cypress run",
    "test:open": "npx cypress open"
  },
  "devDependencies": {
    "cypress": "latest"
  }
}
PKG
      mkdir -p "$PROJECT_PATH/cypress/e2e"
      mkdir -p "$PROJECT_PATH/cypress/support/pages"
      mkdir -p "$PROJECT_PATH/cypress/fixtures"
      cat > "$PROJECT_PATH/cypress.config.js" <<'CYPRESSCONF'
const { defineConfig } = require('cypress');
require('dotenv').config();

module.exports = defineConfig({
  e2e: {
    specPattern: 'cypress/e2e/**/*.cy.js',
    baseUrl: process.env.STAGING_URL || 'http://localhost:3000',
    viewportWidth: 1920,
    viewportHeight: 1080,
    video: false,
    screenshotOnRunFailure: true,
    reporter: 'junit',
    reporterOptions: { mochaFile: 'test-results/results.xml' },
    setupNodeEvents(on, config) { return config; },
  },
});
CYPRESSCONF
      cat > "$PROJECT_PATH/cypress/support/e2e.js" <<'E2E'
// Global Cypress support file
Cypress.on('uncaught:exception', () => false);
E2E
      ;;

    selenium-java|appium-java)
      PROJ_NAME=$(basename "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
      cat > "$PROJECT_PATH/pom.xml" <<MAVENPOM
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.tests</groupId>
  <artifactId>${PROJ_NAME}</artifactId>
  <version>1.0.0</version>
  <dependencies>
    <dependency>
      <groupId>org.seleniumhq.selenium</groupId>
      <artifactId>selenium-java</artifactId>
      <version>4.18.1</version>
    </dependency>
    <dependency>
      <groupId>org.testng</groupId>
      <artifactId>testng</artifactId>
      <version>7.9.0</version>
    </dependency>
    <dependency>
      <groupId>io.github.bonigarcia</groupId>
      <artifactId>webdrivermanager</artifactId>
      <version>5.7.0</version>
    </dependency>
    <dependency>
      <groupId>com.google.code.gson</groupId>
      <artifactId>gson</artifactId>
      <version>2.10.1</version>
    </dependency>
    <dependency>
      <groupId>io.qameta.allure</groupId>
      <artifactId>allure-testng</artifactId>
      <version>2.25.0</version>
    </dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-surefire-plugin</artifactId>
        <version>3.2.5</version>
      </plugin>
    </plugins>
  </build>
</project>
MAVENPOM
      ;;

    appium-python)
      cat > "$PROJECT_PATH/requirements.txt" <<'REQ'
Appium-Python-Client
pytest
allure-pytest
pytest-html
python-dotenv
REQ
      cat > "$PROJECT_PATH/pytest.ini" <<'PYTESTINI'
[pytest]
testpaths = tests
addopts = -v --tb=short --junitxml=test-results/results.xml
PYTESTINI
      cat > "$PROJECT_PATH/config/capabilities.json" <<'CAPS'
{
  "android": {
    "platformName": "Android",
    "automationName": "UiAutomator2",
    "deviceName": "emulator-5554",
    "app": "${APP_PATH}"
  }
}
CAPS
      ;;

    robot-framework)
      cat > "$PROJECT_PATH/requirements.txt" <<'REQ'
robotframework
robotframework-seleniumlibrary
robotframework-browser
REQ
      mkdir -p "$PROJECT_PATH/resources/keywords"
      mkdir -p "$PROJECT_PATH/resources/pages"
      cat > "$PROJECT_PATH/robot.toml" <<'ROBOTCONF'
[tool.robot]
outputdir = "reports"
loglevel = "INFO"
ROBOTCONF
      ;;
  esac

  # init git
  if [ ! -d "$PROJECT_PATH/.git" ]; then
    (cd "$PROJECT_PATH" && git init -q && git add .)
    # If no global git identity, set a local one for this repo only
    if ! git config --global user.email &>/dev/null; then
      (cd "$PROJECT_PATH" && git config user.email "gp-agent@setup.local" && git config user.name "GP Test Agent")
    fi
    (cd "$PROJECT_PATH" && git commit -q -m "chore: initialize $FW_LABEL test project" 2>/dev/null) \
      || (cd "$PROJECT_PATH" && git config user.email "gp-agent@setup.local" && git config user.name "GP Test Agent" && git commit -q -m "chore: initialize $FW_LABEL test project")
    echo "  Git repository initialized."
  fi

  echo ""
  echo "  Project created successfully."
fi

# ── [3/4] Install / Verify Dependencies ─────────────────────────────────────

echo ""
echo "[3/4] Checking dependencies..."
echo ""

mkdir -p "$PROJECT_PATH/test-results"

case "$LANG" in
  javascript|typescript)
    if [ -f "$PROJECT_PATH/package.json" ]; then
      if [ ! -d "$PROJECT_PATH/node_modules" ]; then
        echo "  node_modules not found — running npm install..."
        (cd "$PROJECT_PATH" && npm install)
      else
        echo "  node_modules: OK"
      fi

      # Framework-specific browser install
      case "$FRAMEWORK" in
        playwright-js|playwright-typescript)
          if ! (cd "$PROJECT_PATH" && npx playwright --version &>/dev/null 2>&1); then
            echo "  Installing Playwright browsers..."
            (cd "$PROJECT_PATH" && npx playwright install chromium)
          else
            PW_VER=$(cd "$PROJECT_PATH" && npx playwright --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "installed")
            echo "  Playwright: $PW_VER"
          fi
          ;;
        cypress-js)
          if [ ! -d "$PROJECT_PATH/node_modules/cypress" ]; then
            echo "  Installing Cypress..."
            (cd "$PROJECT_PATH" && npm install)
          else
            echo "  Cypress: OK"
          fi
          ;;
      esac
    else
      echo "  WARNING: No package.json found in $PROJECT_PATH"
    fi
    ;;

  python)
    if [ -f "$PROJECT_PATH/requirements.txt" ]; then
      # Check if key packages are installed
      SAMPLE_PKG=$(head -1 "$PROJECT_PATH/requirements.txt" | sed 's/[>=<].*//' | tr '[:upper:]' '[:lower:]')
      if python3 -c "import pkg_resources; pkg_resources.require(open('$PROJECT_PATH/requirements.txt').read().splitlines())" &>/dev/null 2>&1; then
        echo "  Python dependencies: OK"
      else
        echo "  Installing Python dependencies..."
        pip install -r "$PROJECT_PATH/requirements.txt" --quiet
        echo "  Dependencies installed."
        # Playwright Python: install browsers
        if echo "$FRAMEWORK" | grep -q "playwright"; then
          echo "  Installing Playwright browsers..."
          playwright install chromium 2>/dev/null || python3 -m playwright install chromium 2>/dev/null || echo "  (run: playwright install chromium)"
        fi
      fi
    else
      echo "  No requirements.txt found."
    fi
    ;;

  java)
    if [ -f "$PROJECT_PATH/pom.xml" ]; then
      if command -v mvn &>/dev/null; then
        echo "  Downloading Maven dependencies (this may take a moment)..."
        (cd "$PROJECT_PATH" && mvn dependency:resolve -q 2>/dev/null) && echo "  Maven dependencies: OK" || echo "  WARNING: mvn dependency:resolve failed — check pom.xml"
      else
        echo "  Maven (mvn) not found — install it to resolve Java dependencies."
        echo "  Download: https://maven.apache.org/download.cgi"
      fi
    else
      echo "  No pom.xml found."
    fi
    ;;
esac

echo ""

# ── [4/4] Write .env ─────────────────────────────────────────────────────────

echo "[4/4] Writing .env file..."

# Load existing to preserve any extra vars (Jira, GitLab, etc.)
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE" 2>/dev/null || true; set +a
fi

cat > "$ENV_FILE" <<EOF
# GP Test Agent — Environment Variables
# Generated by setup.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Re-run ./scripts/setup.sh to regenerate.

# ── Test Project ──────────────────────────────────────────────────────────────
GP_TEST_PROJECT_PATH=${PROJECT_PATH}
GP_FRAMEWORK=${FRAMEWORK}
GP_PR_TARGET_BRANCH=${GP_PR_TARGET_BRANCH:-main}

# ── Test Environment ──────────────────────────────────────────────────────────
STAGING_URL=${STAGING_URL:-https://staging.yourapp.com}
TEST_USER=${TEST_USER:-automation@yourapp.com}
TEST_PASSWORD=${TEST_PASSWORD:-yourpassword}
TEST_ENV=staging
HEADLESS=${HEADLESS:-true}
TEST_TIMEOUT=${TEST_TIMEOUT:-30000}

# ── Version Control ───────────────────────────────────────────────────────────
GH_TOKEN=${GH_TOKEN:-}
GH_REPO=${GH_REPO:-}
GITLAB_TOKEN=${GITLAB_TOKEN:-}
ADO_ORG=${ADO_ORG:-}
ADO_PROJECT=${ADO_PROJECT:-}
ADO_PAT=${ADO_PAT:-}

# ── Jira (optional — for /gp-test-agent with Jira tickets) ───────────────────
JIRA_BASE_URL=${JIRA_BASE_URL:-}
JIRA_USER=${JIRA_USER:-}
JIRA_TOKEN=${JIRA_TOKEN:-}

# ── Claude Code ───────────────────────────────────────────────────────────────
CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1
EOF

if [ "$IS_WINDOWS" = true ]; then
  echo "  Written to $ENV_FILE"
else
  chmod 600 "$ENV_FILE"
  echo "  Written to $ENV_FILE (permissions: 600)"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────

echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "  Framework : $FW_LABEL"
echo "  Project   : $PROJECT_PATH"
echo ""
echo "  Next steps:"
echo ""
echo "  1) Edit .env — fill in your app URL, test credentials,"
echo "     and VCS token (GH_TOKEN / GITLAB_TOKEN / ADO_PAT)."
echo ""
echo "  2) Run the agent with a ticket:"
echo ""
echo "       claude"
echo "       /gp-test-agent PROJ-123"
echo ""
echo "  3) Or generate tests with more options:"
echo ""
echo "       /gp-test-agent PROJ-123 --framework $FRAMEWORK --vcs github --auto"
echo ""
echo "  4) To fix failing tests:"
echo ""
echo "       /gp-fix-tests $PROJECT_PATH/test-results/results.xml"
echo ""
echo "  5) To scan for automation candidates:"
echo ""
echo "       /gp-scan-tickets --platform jira --label qa-ready"
echo ""
echo "============================================"
