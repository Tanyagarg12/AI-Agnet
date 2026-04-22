import { Page, expect } from "@playwright/test";
import { BasePage } from "./BasePage";
import selectors from "../config/selectors/orangehrm.json";

/**
 * DashboardPage POM for OrangeHRM Dashboard module.
 * All selectors sourced from config/selectors/orangehrm.json.
 */
export class DashboardPage extends BasePage {
    constructor(page: Page) {
        super(page);
    }

    /** Assert that the Dashboard page is fully loaded. */
    async isLoaded(): Promise<void> {
        await expect(
            this.page,
            "URL should contain the dashboard path"
        ).toHaveURL(new RegExp(selectors.pages.dashboard.url_pattern), { timeout: 10000 });

        const heading = this.page
            .locator(selectors.common.page_heading)
            .filter({ hasText: selectors.pages.dashboard.page_heading.expected_text })
            .first();
        await expect(
            heading,
            `"${selectors.pages.dashboard.page_heading.expected_text}" heading should be visible`
        ).toBeVisible({ timeout: 10000 });
    }

    /** Assert that dashboard widgets are rendered. */
    async hasWidgets(): Promise<void> {
        const widgets = this.page.locator(selectors.pages.dashboard.widget_selector);
        await expect(
            widgets.first(),
            "At least one dashboard widget should be visible"
        ).toBeVisible({ timeout: 10000 });
    }
}
