import { Page, expect } from "@playwright/test";
import { BasePage } from "./BasePage";
import selectors from "../config/selectors/orangehrm.json";

/**
 * MyInfoPage POM for OrangeHRM My Info section.
 * Note: My Info opens within the PIM module. The page heading shows "PIM"
 * and the URL contains "viewPersonalDetails" with a user-specific empNumber.
 * All selectors sourced from config/selectors/orangehrm.json.
 */
export class MyInfoPage extends BasePage {
    constructor(page: Page) {
        super(page);
    }

    /** Assert that the My Info page is fully loaded. */
    async isLoaded(): Promise<void> {
        await expect(
            this.page,
            "URL should contain viewPersonalDetails for My Info page"
        ).toHaveURL(/viewPersonalDetails/, { timeout: 10000 });

        const heading = this.page
            .locator(selectors.common.page_heading)
            .filter({ hasText: selectors.pages.my_info.page_heading.expected_text })
            .first();
        await expect(
            heading,
            `"${selectors.pages.my_info.page_heading.expected_text}" heading should be visible on My Info page`
        ).toBeVisible({ timeout: 10000 });
    }
}
