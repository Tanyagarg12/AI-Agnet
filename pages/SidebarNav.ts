import { Page, expect } from "@playwright/test";
import { BasePage } from "./BasePage";
import selectors from "../config/selectors/orangehrm.json";

/**
 * SidebarNav POM for OrangeHRM main navigation menu.
 * All selectors sourced from config/selectors/orangehrm.json.
 */
export class SidebarNav extends BasePage {
    constructor(page: Page) {
        super(page);
    }

    /**
     * Click a sidebar module by its visible text name.
     * Waits for DOM content to load after navigation.
     */
    async clickModule(moduleName: string): Promise<void> {
        const menuItem = this.page
            .locator(selectors.sidebar.menu_item_link)
            .filter({ hasText: moduleName });

        await expect(
            menuItem,
            `Sidebar menu item "${moduleName}" should be visible`
        ).toBeVisible({ timeout: 10000 });

        await menuItem.click();
        await this.page.waitForLoadState("domcontentloaded");
    }

    /**
     * Check whether a sidebar module is currently in active state.
     */
    async isModuleActive(moduleName: string): Promise<boolean> {
        const activeItems = this.page.locator(selectors.sidebar.active_item);
        const count = await activeItems.count();

        for (let i = 0; i < count; i++) {
            const text = await activeItems.nth(i).textContent();
            if (text && text.trim().includes(moduleName)) {
                return true;
            }
        }
        return false;
    }
}
