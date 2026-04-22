# E2E Framework Catalog

Summary of the OX Security E2E test automation framework structure.

## Directory Layout

```
framework/
├── tests/
│   ├── UI/                   # 105+ test suites organized by feature
│   │   ├── issues/           # Issue management tests
│   │   ├── sbom/             # SBOM (Software Bill of Materials) tests
│   │   ├── dashboard/        # Dashboard/overview tests
│   │   ├── policies/         # Policy management tests
│   │   ├── settings/         # Settings/configuration tests
│   │   ├── connectors/       # Connector/integration tests
│   │   ├── reports/          # Report generation tests
│   │   ├── cbom/             # Cloud BOM tests
│   │   └── users/            # User management tests
│   ├── api-tests/
│   │   ├── queries/          # GraphQL .gql query files
│   │   ├── query-tests/      # API test implementations (*.api.test.js)
│   │   ├── expected-results/ # Expected responses per environment
│   │   ├── variables/        # Query variables per environment
│   │   └── fixtures/         # API test fixtures
│   ├── backend/              # Backend tests
│   ├── performance/          # Performance tests
│   └── scripts/              # Test utility scripts
├── actions/                  # Reusable action modules per feature
│   ├── general.js            # navigation(), common actions
│   ├── login.js              # verifyLoginPage(), closeWhatsNew()
│   ├── cbom.js               # Cloud BOM actions
│   ├── issues.js             # Issues page actions
│   └── ...                   # One module per feature area
├── selectors/                # UI element selectors as JSON files
│   ├── general.json          # Common selectors (menus, navigation)
│   ├── login.json            # Login page selectors
│   └── ...                   # One file per feature area
├── utils/
│   ├── setHooks.js           # Test hooks: setBeforeAll, setBeforeEach, setAfterEach, setAfterAll
│   ├── generateAccessToken.js # API token generation
│   └── mongoDBClient.js      # Database client utility
├── params/
│   └── global.json           # Timeouts: shortTimeout=4s, mediumTimeout=30s, longTimeout=60s, API_TIMEOUT=60s
├── env/                      # Environment config files
│   ├── .env.dev              # Development environment
│   ├── .env.stg              # Staging environment
│   ├── .env.prod             # Production environment
│   ├── .env.onPrem1          # On-premises 1
│   ├── .env.onPrem2          # On-premises 2
│   ├── .env.azureUS          # Azure US
│   └── .env.us               # US region
├── reporters/                # Custom Playwright reporters
│   ├── humanReadableReporter.js
│   └── apiTestReporter.js
├── logging/                  # Winston-based logging
├── screenshot/               # Failure screenshots (per environment)
├── video/                    # Failure videos (per environment)
├── files/                    # Test data fixtures and expected values
└── playwright.config.js      # Playwright configuration
```

## Playwright Config Highlights

- Workers: 1 (serial execution)
- Retries: 1
- Bail: true (stop on first failure)
- Timeout: 500000ms
- Expect timeout: 10000ms
- Action timeout: 10000ms
- Viewport: 1920x1080
- Video: retain-on-failure
- Screenshot: only-on-failure
- Trace: on-first-retry

## Running Tests

```bash
cd framework/

# UI test
envFile=.env.dev npx playwright test <testName>.test

# API test
envFile=.env.stg npx playwright test query-tests/<category>/<testName>.api.test

# With tag filtering
envFile=.env.stg npx playwright test --grep @sanity
```

## Key Patterns

- **Module system**: CommonJS `require()` -- no ES modules
- **Style**: Double quotes, 4-space indent, semicolons, no trailing commas (Prettier)
- **Test mode**: Always serial (`mode: "serial"`)
- **Login flow**: Tests #1-#2 are always navigate + login
- **Actions**: Functions in `actions/` that accept `page` object
- **Selectors**: JSON files with XPath + pipe fallbacks, prefer data-testid
- **Hooks**: setBeforeAll initializes browser/context/page
- **Logging**: Winston via `logger.info()`
- **Assertions**: `expect()` for blocking, `expect.soft()` for non-blocking

## Environment Variables (from .env files)

| Variable | Purpose |
|----------|---------|
| SANITY_ORG_NAME | Organization name for testing |
| SANITY_USER | Test user email |
| USER_PASSWORD | Test user password |
| LOGIN_URL | Login page URL |
| POST_LOGIN_URL | Expected URL after login |
| ENVIRONMENT | Environment name (dev, stg, prod, etc.) |
| TEST_TIMEOUT | Test timeout in milliseconds |
| API_URL | API base URL (for API tests) |
