# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: orangehrm-navigation.spec.ts >> KAN-4: OrangeHRM Navigation >> #1 Navigate to login page
- Location: tests\orangehrm-navigation.spec.ts:45:9

# Error details

```
Error: Login form should be visible on the login page

expect(locator).toBeVisible() failed

Locator: locator('.orangehrm-login-form')
Expected: visible
Timeout: 15000ms
Error: element(s) not found

Call log:
  - Login form should be visible on the login page with timeout 15000ms
  - waiting for locator('.orangehrm-login-form')

```

# Test source

```ts
  1  | import { Page, expect } from "@playwright/test";
  2  | import { BasePage } from "./BasePage";
  3  | import selectors from "../config/selectors/orangehrm.json";
  4  | 
  5  | /**
  6  |  * LoginPage POM for OrangeHRM authentication.
  7  |  * All selectors sourced from config/selectors/orangehrm.json.
  8  |  */
  9  | export class LoginPage extends BasePage {
  10 |     constructor(page: Page) {
  11 |         super(page);
  12 |     }
  13 | 
  14 |     /** Navigate to the login page URL. */
  15 |     async navigateToLogin(): Promise<void> {
  16 |         await this.navigate(selectors.login.page_url);
  17 |         await this.page.waitForLoadState("domcontentloaded");
  18 |     }
  19 | 
  20 |     /** Check whether the login form is visible on the page. */
  21 |     async isLoginPageVisible(): Promise<void> {
  22 |         await expect(
  23 |             this.locator(selectors.login.login_form),
  24 |             "Login form should be visible on the login page"
> 25 |         ).toBeVisible({ timeout: 15000 });
     |           ^ Error: Login form should be visible on the login page
  26 | 
  27 |         await expect(
  28 |             this.locator(selectors.login.username_input),
  29 |             "Username input should be visible on the login page"
  30 |         ).toBeVisible();
  31 | 
  32 |         await expect(
  33 |             this.locator(selectors.login.password_input),
  34 |             "Password input should be visible on the login page"
  35 |         ).toBeVisible();
  36 |     }
  37 | 
  38 |     /**
  39 |      * Fill credentials and submit the login form.
  40 |      * Waits for redirect to dashboard after successful login.
  41 |      */
  42 |     async login(username: string, password: string): Promise<void> {
  43 |         await this.page.fill(selectors.login.username_input, username);
  44 |         await this.page.fill(selectors.login.password_input, password);
  45 |         await this.page.click(selectors.login.login_button);
  46 |         await this.page.waitForURL("**/dashboard/index", { timeout: 15000 });
  47 |     }
  48 | }
  49 | 
```