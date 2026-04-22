import { Page, expect } from "@playwright/test";
import { BasePage } from "./BasePage";
import selectors from "../config/selectors/orangehrm.json";

/**
 * RecruitmentPage POM for OrangeHRM Recruitment module.
 * All selectors sourced from config/selectors/orangehrm.json.
 */
export class RecruitmentPage extends BasePage {
    constructor(page: Page) {
        super(page);
    }

    /** Assert that the Recruitment page is fully loaded. */
    async isLoaded(): Promise<void> {
        await expect(
            this.page,
            "URL should contain the recruitment path"
        ).toHaveURL(new RegExp(selectors.pages.recruitment.url_pattern), { timeout: 10000 });

        const heading = this.page
            .locator(selectors.common.page_heading)
            .filter({ hasText: selectors.pages.recruitment.page_heading.expected_text })
            .first();
        await expect(
            heading,
            `"${selectors.pages.recruitment.page_heading.expected_text}" heading should be visible`
        ).toBeVisible({ timeout: 10000 });
    }
}
