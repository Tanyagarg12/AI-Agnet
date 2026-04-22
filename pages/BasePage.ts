import { Page, Locator } from "@playwright/test";

/**
 * BasePage — thin wrapper around Playwright's Page object.
 * All POM page classes extend this base.
 * Generated for KAN-4 OrangeHRM navigation tests.
 */
export class BasePage {
    protected page: Page;

    constructor(page: Page) {
        this.page = page;
    }

    async navigate(path: string): Promise<void> {
        const baseUrl = process.env.STAGING_URL || "https://opensource-demo.orangehrmlive.com";
        await this.page.goto(`${baseUrl}${path}`);
    }

    async waitForURL(urlPattern: string | RegExp, timeout = 30000): Promise<void> {
        await this.page.waitForURL(urlPattern, { timeout });
    }

    async getTitle(): Promise<string> {
        return this.page.title();
    }

    protected locator(selector: string): Locator {
        return this.page.locator(selector);
    }
}
