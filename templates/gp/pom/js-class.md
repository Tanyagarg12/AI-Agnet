# JavaScript Page Object Model Template

Use this template when generating POM classes for Playwright (JS) or Selenium (JS).

## BasePage (create once per project)

```javascript
// pages/BasePage.js
const selectors = {};

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

    async isVisible(selector) {
        try {
            await this.page.waitForSelector(selector, { state: 'visible', timeout: 5000 });
            return true;
        } catch {
            return false;
        }
    }

    async waitForNavigation(url) {
        await this.page.waitForURL(url);
    }

    async waitForApiResponse(urlPattern) {
        await this.page.waitForResponse(urlPattern);
    }

    async takeScreenshot(name) {
        await this.page.screenshot({ path: `test-results/${name}.png`, fullPage: true });
    }

    async selectDropdownOption(selector, value) {
        await this.page.selectOption(selector, value);
    }

    async getCount(selector) {
        return await this.page.locator(selector).count();
    }
}

module.exports = { BasePage };
```

## Feature Page Object (one per page/feature)

```javascript
// pages/<FeatureName>Page.js
const { BasePage } = require('./BasePage');
const selectors = require('../config/selectors/<feature>.json');

class <FeatureName>Page extends BasePage {
    constructor(page) {
        super(page);
    }

    // Navigation
    async navigateTo(baseUrl) {
        await super.navigateTo(`${baseUrl}/<page-path>`);
        await this.page.waitForSelector(selectors.<mainContainer>);
    }

    // Actions — name after user intent, not technical operation
    async click<Action>() {
        await this.clickElement(selectors.<actionElement>);
    }

    async fill<FieldName>(value) {
        await this.fillInput(selectors.<inputElement>, value);
    }

    async select<FilterName>(value) {
        await this.clickElement(selectors.<filterTrigger>);
        await this.clickElement(`//option[text()="${value}"]`);
    }

    // Getters — return meaningful values for assertions
    async get<ItemCount>() {
        const text = await this.getText(selectors.<counter>);
        return parseInt(text, 10);
    }

    async get<TableRows>() {
        return await this.getCount(selectors.<tableRow>);
    }

    async is<ElementVisible>() {
        return await this.isVisible(selectors.<element>);
    }

    // Wait helpers — encapsulate timing logic
    async waitFor<DataLoad>() {
        await this.waitForApiResponse('**/<api-endpoint>**');
    }
}

module.exports = { <FeatureName>Page };
```

## Selectors JSON (always separate from page class)

```json
// config/selectors/<feature>.json
{
    "_comment": "Selectors for <FeatureName>. Use XPath with | for fallbacks.",
    "mainContainer": "//*[@data-testid='<main-container>'] | //div[@class='<fallback-class>']",
    "<actionElement>": "//*[@data-testid='<action-btn>'] | //button[text()='<button-text>']",
    "<inputElement>": "//*[@data-testid='<input-id>'] | //input[@name='<input-name>']",
    "<filterTrigger>": "//*[@data-testid='<filter-dropdown>'] | //div[contains(@class,'filter')]",
    "<counter>": "//*[@data-testid='<count-element>']",
    "<tableRow>": "//*[@data-testid='<table>']//tr[not(contains(@class,'header'))]",
    "<element>": "//*[@data-testid='<element-id>']"
}
```

## Rules for Generated Classes

1. ALL selectors via the `selectors` import — NEVER inline strings like `await page.click('button.my-btn')`
2. Method names describe USER ACTIONS: `clickFilterButton()` not `clickButton()`
3. Return meaningful types from getters: counts (int), text (string), visibility (bool)
4. Encapsulate waits inside page methods — test files should never call `waitFor` directly
5. Extend BasePage — never copy-paste BasePage methods into subclasses
6. One responsibility per method — `clickFilterButton()` opens filter, it does NOT verify results
