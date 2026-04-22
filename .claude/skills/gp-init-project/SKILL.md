---
name: gp-init-project
description: >
  Scaffold a complete, production-ready test automation project from scratch for
  any supported framework and language. Creates the full folder structure, config
  files, base classes, CI/CD templates, and reporting setup.
argument-hint: "--framework <id> [--language js|ts|python|java] [--path /abs/path] [--project-name my-tests] [--reporter allure|html|both] [--ci github|gitlab|none]"
---

# GP Init Project — Test Project Scaffolder

You are scaffolding a brand-new test automation project. No ticket is required — this creates a clean, best-practice project structure ready to write tests in.

## Step 1: Parse Arguments

```
FLAGS:
  --framework     REQUIRED. Framework ID from config/frameworks/*.json
  --language      Override framework default language
  --path          Absolute path for the new project (default: ./test-projects/<project-name>)
  --project-name  Name for the project directory (default: my-test-project)
  --reporter      Reporting format: allure, html, or both (default: both)
  --ci            CI/CD template to generate: github, gitlab, none (default: none)
```

If `--framework` not provided, show selection menu:
```
Select a testing framework:
  1. playwright-js     - Playwright (JavaScript)
  2. playwright-ts     - Playwright (TypeScript)
  3. playwright-python - Playwright (Python)
  4. selenium-python   - Selenium (Python)
  5. selenium-java     - Selenium (Java + TestNG)
  6. cypress-js        - Cypress (JavaScript)
  7. appium-python     - Appium (Python) for mobile
  8. appium-java       - Appium (Java) for mobile
  9. robot-framework   - Robot Framework
```

## Step 2: Load Framework Config

```bash
cat config/frameworks/<framework>.json
```

## Step 3: Create Project Structure

Create the following based on framework config's `project_structure`:

```
<project_root>/
├── tests/                    # Test files
├── pages/                    # Page Object Model classes
├── helpers/                  # Reusable utility functions
├── fixtures/                 # Test fixtures and data providers
├── config/
│   ├── environments.json     # Environment URLs, credentials (template values)
│   ├── selectors/            # Selector JSON files per feature
│   └── test-data.json        # Test data configuration
├── reports/                  # Generated reports (gitignored)
├── <framework-config-file>   # playwright.config.js / pytest.ini / pom.xml etc.
├── <base-page-file>          # BasePage class with common methods
├── <base-test-file>          # BaseTest class with setup/teardown
├── .env.example              # Environment variable template
├── .gitignore                # Framework-appropriate gitignore
└── README.md                 # Project documentation
```

## Step 4: Generate Base Classes

Use `templates/gp/pom/<language>.md` as the template for:
- `BasePage.<ext>` — common page interactions (click, fill, wait, assert visible)
- `BaseTest.<ext>` — test lifecycle hooks (setup driver, teardown, screenshot on failure)

## Step 5: Generate Config Files

**environments.json** (template — never hardcode real values):
```json
{
  "staging": {
    "base_url": "${STAGING_URL}",
    "username": "${STAGING_USER}",
    "password": "${STAGING_PASSWORD}"
  },
  "dev": {
    "base_url": "${DEV_URL}",
    "username": "${DEV_USER}",
    "password": "${DEV_PASSWORD}"
  }
}
```

**selectors/example.json** (empty template):
```json
{
  "_comment": "Add selectors for each feature. Use XPath with | pipe for fallbacks.",
  "loginButton": "//button[@data-testid='login-btn'] | //button[text()='Login']",
  "emailInput": "//input[@type='email'] | //input[@name='email']"
}
```

**.env.example**:
```
STAGING_URL=https://staging.yourapp.com
STAGING_USER=automation@yourapp.com
STAGING_PASSWORD=your-password
DEV_URL=https://dev.yourapp.com
```

## Step 6: Install Dependencies

Run framework `install_commands` from config:
```bash
./scripts/gp-install-framework.sh <framework>
```

## Step 7: Setup Reporting

Based on `--reporter` flag, install and configure:
- **allure**: Run `./scripts/gp-setup-allure.sh <framework>`
- **html**: Built into most frameworks, add to config
- **both**: Run both

## Step 8: Generate CI Template (Optional)

If `--ci github`:
```yaml
# .github/workflows/tests.yml
name: Automated Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run tests
        run: <framework run command>
      - name: Upload reports
        uses: actions/upload-artifact@v3
        with:
          name: test-reports
          path: reports/
```

If `--ci gitlab`:
```yaml
# .gitlab-ci.yml
test:
  script:
    - <install commands>
    - <run command>
  artifacts:
    paths:
      - reports/
```

## Step 9: Initialize Git

```bash
cd <project_root>
git init
git add .
git commit -m "chore: initialize test automation project with <framework>"
```

## Final Output

```
✅ Project Initialized: <project_name>
   Framework: <FRAMEWORK>    Language: <LANGUAGE>
   Location: <PROJECT_PATH>

   Structure:
   📁 tests/       → write test files here
   📁 pages/       → page object model classes
   📁 helpers/     → reusable utility functions
   📁 config/      → environments, selectors, test data

   Next steps:
   1. Copy .env.example → .env and fill in your values
   2. Run: /gp-test-agent <your-ticket> --project-path <PROJECT_PATH>
   3. Or write your first test: tests/example.spec.<ext>
```
