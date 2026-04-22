import { Page, expect } from "@playwright/test";
import selectors from "../config/selectors/orangehrm.json";

/**
 * Login helper for OrangeHRM.
 * Uses selectors from config/selectors/orangehrm.json — never hardcoded.
 */
export async function loginAs(
    page: Page,
    username: string,
    password: string
): Promise<void> {
    await page.fill(selectors.login.username_input, username);
    await page.fill(selectors.login.password_input, password);
    await page.click(selectors.login.login_button);
    await page.waitForURL("**/dashboard/index", { timeout: 15000 });
    await expect(
        page.locator(selectors.common.page_heading).first(),
        "Dashboard heading should be visible after login"
    ).toBeVisible({ timeout: 10000 });
}
