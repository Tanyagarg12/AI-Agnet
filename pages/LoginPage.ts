import { Page, expect } from "@playwright/test";
import { BasePage } from "./BasePage";
import selectors from "../config/selectors/orangehrm.json";

/**
 * LoginPage POM for OrangeHRM authentication.
 * All selectors sourced from config/selectors/orangehrm.json.
 */
export class LoginPage extends BasePage {
    constructor(page: Page) {
        super(page);
    }

    /** Navigate to the login page URL. */
    async navigateToLogin(): Promise<void> {
        await this.navigate(selectors.login.page_url);
        await this.page.waitForLoadState("domcontentloaded");
    }

    /** Check whether the login form is visible on the page. */
    async isLoginPageVisible(): Promise<void> {
        await expect(
            this.locator(selectors.login.login_form),
            "Login form should be visible on the login page"
        ).toBeVisible({ timeout: 15000 });

        await expect(
            this.locator(selectors.login.username_input),
            "Username input should be visible on the login page"
        ).toBeVisible();

        await expect(
            this.locator(selectors.login.password_input),
            "Password input should be visible on the login page"
        ).toBeVisible();
    }

    /**
     * Fill credentials and submit the login form.
     * Waits for redirect to dashboard after successful login.
     */
    async login(username: string, password: string): Promise<void> {
        await this.page.fill(selectors.login.username_input, username);
        await this.page.fill(selectors.login.password_input, password);
        await this.page.click(selectors.login.login_button);
        await this.page.waitForURL("**/dashboard/index", { timeout: 15000 });
    }
}
