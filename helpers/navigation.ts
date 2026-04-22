import { Page, expect } from "@playwright/test";
import selectors from "../config/selectors/orangehrm.json";

/**
 * Navigate to a sidebar module by clicking its menu item text.
 * Uses selectors from config/selectors/orangehrm.json.
 */
export async function navigateToModule(
    page: Page,
    moduleName: string
): Promise<void> {
    const menuItem = page
        .locator(selectors.sidebar.menu_item_link)
        .filter({ hasText: moduleName });
    await menuItem.click();
    await page.waitForLoadState("domcontentloaded");
}

/**
 * Assert that the current page matches the expected URL pattern and heading text.
 * Every assertion includes a descriptive error message.
 */
export async function assertPageLoaded(
    page: Page,
    urlSubstring: string,
    headingText: string
): Promise<void> {
    await expect(
        page,
        `URL should contain "${urlSubstring}"`
    ).toHaveURL(new RegExp(urlSubstring), { timeout: 10000 });

    const heading = page
        .locator(selectors.common.page_heading)
        .filter({ hasText: headingText })
        .first();
    await expect(
        heading,
        `"${headingText}" heading should be visible on the page`
    ).toBeVisible({ timeout: 10000 });
}
