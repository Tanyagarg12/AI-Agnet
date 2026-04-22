import { Page, expect } from "@playwright/test";
import { BasePage } from "./BasePage";
import selectors from "../config/selectors/orangehrm.json";

/**
 * LeavePage POM for OrangeHRM Leave module.
 * All selectors sourced from config/selectors/orangehrm.json.
 */
export class LeavePage extends BasePage {
    constructor(page: Page) {
        super(page);
    }

    /** Assert that the Leave page is fully loaded. */
    async isLoaded(): Promise<void> {
        await expect(
            this.page,
            "URL should contain the leave path"
        ).toHaveURL(new RegExp(selectors.pages.leave.url_pattern), { timeout: 10000 });

        const heading = this.page
            .locator(selectors.common.page_heading)
            .filter({ hasText: selectors.pages.leave.page_heading.expected_text })
            .first();
        await expect(
            heading,
            `"${selectors.pages.leave.page_heading.expected_text}" heading should be visible`
        ).toBeVisible({ timeout: 10000 });
    }
}
