import { Page, expect } from "@playwright/test";
import { BasePage } from "./BasePage";
import selectors from "../config/selectors/orangehrm.json";

/**
 * PerformancePage POM for OrangeHRM Performance module.
 * All selectors sourced from config/selectors/orangehrm.json.
 */
export class PerformancePage extends BasePage {
    constructor(page: Page) {
        super(page);
    }

    /** Assert that the Performance page is fully loaded. */
    async isLoaded(): Promise<void> {
        await expect(
            this.page,
            "URL should contain the performance path"
        ).toHaveURL(new RegExp(selectors.pages.performance.url_pattern), { timeout: 10000 });

        const heading = this.page
            .locator(selectors.common.page_heading)
            .filter({ hasText: selectors.pages.performance.page_heading.expected_text })
            .first();
        await expect(
            heading,
            `"${selectors.pages.performance.page_heading.expected_text}" heading should be visible`
        ).toBeVisible({ timeout: 10000 });
    }
}
