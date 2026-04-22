import { Page, expect } from "@playwright/test";
import { BasePage } from "./BasePage";
import selectors from "../config/selectors/orangehrm.json";

/**
 * AdminPage POM for OrangeHRM Admin module.
 * All selectors sourced from config/selectors/orangehrm.json.
 */
export class AdminPage extends BasePage {
    constructor(page: Page) {
        super(page);
    }

    /** Assert that the Admin page is fully loaded. */
    async isLoaded(): Promise<void> {
        await expect(
            this.page,
            "URL should contain the admin path"
        ).toHaveURL(new RegExp(selectors.pages.admin.url_pattern), { timeout: 10000 });

        const heading = this.page
            .locator(selectors.common.page_heading)
            .filter({ hasText: selectors.pages.admin.page_heading.expected_text })
            .first();
        await expect(
            heading,
            `"${selectors.pages.admin.page_heading.expected_text}" heading should be visible`
        ).toBeVisible({ timeout: 10000 });
    }
}
