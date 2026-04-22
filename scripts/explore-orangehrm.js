/**
 * explore-orangehrm.js
 * Exploration script to gather selectors from OrangeHRM demo site.
 * Runs headless, outputs JSON data for browser-data.json.
 */

const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

const BASE_URL = "https://opensource-demo.orangehrmlive.com";
const LOGIN_URL = `${BASE_URL}/web/index.php/auth/login`;
const MEMORY_DIR = path.join(__dirname, "../memory/gp-runs/GP-20260416-142117");
const SELECTORS_DIR = path.join(__dirname, "../config/selectors");

const MENU_ITEMS = [
    "Admin",
    "PIM",
    "Leave",
    "Time",
    "Recruitment",
    "My Info",
    "Performance",
    "Dashboard",
    "Directory",
];

async function sleep(ms) {
    return new Promise((r) => setTimeout(r, ms));
}

async function safeEval(page, fn, fallback = null) {
    try {
        return await page.evaluate(fn);
    } catch (e) {
        return fallback;
    }
}

async function getElementInfo(page, selector) {
    try {
        const el = await page.locator(selector).first();
        if (await el.isVisible()) {
            const tag = await safeEval(page, () => {
                const el = document.querySelector(selector);
                return el ? el.tagName.toLowerCase() : null;
            });
            return { selector, visible: true, tag };
        }
    } catch (e) {}
    return { selector, visible: false };
}

async function captureLoginPageSelectors(page) {
    console.log("Navigating to login page...");
    await page.goto(LOGIN_URL, { waitUntil: "networkidle", timeout: 30000 });
    await sleep(2000);

    // Take screenshot
    const screenshotPath = path.join(MEMORY_DIR, "screenshots", "login.png");
    fs.mkdirSync(path.dirname(screenshotPath), { recursive: true });
    await page.screenshot({ path: screenshotPath, fullPage: false });
    console.log("Login screenshot saved.");

    // Gather selectors for login form elements
    const loginData = await page.evaluate(() => {
        const result = {};

        // Username input
        const userInput = document.querySelector("input[name='username']");
        if (userInput) {
            result.username = {
                css: "input[name='username']",
                xpath: "//input[@name='username']",
                data_testid: userInput.getAttribute("data-testid") || null,
                aria_label: userInput.getAttribute("aria-label") || null,
                placeholder: userInput.getAttribute("placeholder") || null,
                type: userInput.type,
            };
        }

        // Password input
        const passInput = document.querySelector("input[name='password']");
        if (passInput) {
            result.password = {
                css: "input[name='password']",
                xpath: "//input[@name='password']",
                data_testid: passInput.getAttribute("data-testid") || null,
                aria_label: passInput.getAttribute("aria-label") || null,
                placeholder: passInput.getAttribute("placeholder") || null,
                type: passInput.type,
            };
        }

        // Login button
        const loginBtn = document.querySelector("button[type='submit']");
        if (loginBtn) {
            result.login_button = {
                css: "button[type='submit']",
                xpath: "//button[@type='submit']",
                data_testid: loginBtn.getAttribute("data-testid") || null,
                aria_label: loginBtn.getAttribute("aria-label") || null,
                text: loginBtn.textContent.trim(),
            };
        }

        // Form container
        const form = document.querySelector(".orangehrm-login-form") ||
                     document.querySelector("form") ||
                     document.querySelector(".login-form");
        if (form) {
            const classes = Array.from(form.classList).join(".");
            result.login_form = {
                css: form.className ? `.${Array.from(form.classList).join(".")}` : "form",
                xpath: "//form",
                data_testid: form.getAttribute("data-testid") || null,
            };
        }

        // Login page container / card
        const card = document.querySelector(".orangehrm-login-container") ||
                     document.querySelector(".login-container") ||
                     document.querySelector("[class*='login-container']");
        if (card) {
            result.login_container = {
                css: `.${Array.from(card.classList).join(".")}`,
                xpath: "//div[contains(@class,'login-container')]",
            };
        }

        // OrangeHRM logo / brand title
        const brand = document.querySelector(".orangehrm-login-brand") ||
                      document.querySelector("[class*='brand']") ||
                      document.querySelector(".login-header") ||
                      document.querySelector("h6");
        if (brand) {
            result.page_title = {
                css: `.${Array.from(brand.classList).join(".")}`,
                text: brand.textContent.trim(),
            };
        }

        return result;
    });

    console.log("Login selectors:", JSON.stringify(loginData, null, 2));
    return loginData;
}

async function login(page) {
    console.log("Logging in...");
    await page.fill("input[name='username']", "Admin");
    await page.fill("input[name='password']", "admin123");
    await page.click("button[type='submit']");
    await page.waitForURL("**/dashboard/**", { timeout: 15000 });
    console.log("Logged in. Current URL:", page.url());
    await sleep(2000);
}

async function captureSidebarSelectors(page) {
    console.log("Capturing sidebar selectors...");

    const sidebarData = await page.evaluate(() => {
        const result = { items: {} };

        // Sidebar container
        const sidebar = document.querySelector(".oxd-sidepanel") ||
                        document.querySelector("[class*='sidepanel']") ||
                        document.querySelector("nav") ||
                        document.querySelector("aside");
        if (sidebar) {
            const cls = Array.from(sidebar.classList);
            result.container = {
                css: cls.length ? `.${cls.join(".")}` : "nav",
                xpath: "//nav | //aside",
                class_names: cls,
            };
        }

        // Nav items - look for menu list items
        const navItems = document.querySelectorAll(".oxd-main-menu-item--name") ||
                         document.querySelectorAll("[class*='menu-item']");

        // Try to find all sidebar links/items
        const allLinks = document.querySelectorAll(".oxd-main-menu a, .oxd-sidepanel a, nav a, aside a");
        const items = [];
        allLinks.forEach((link) => {
            const text = link.textContent.trim();
            if (text) {
                const cls = Array.from(link.classList);
                items.push({
                    text,
                    href: link.getAttribute("href"),
                    css: cls.length ? `.${cls[0]}` : "a",
                    data_testid: link.getAttribute("data-testid") || null,
                    aria_label: link.getAttribute("aria-label") || null,
                });
            }
        });
        result.nav_links = items;

        // Try menu item spans
        const menuSpans = document.querySelectorAll(".oxd-main-menu-item--name");
        const spanItems = [];
        menuSpans.forEach((span) => {
            spanItems.push({
                text: span.textContent.trim(),
                css: ".oxd-main-menu-item--name",
                xpath: `//span[contains(@class,'oxd-main-menu-item--name') and text()='${span.textContent.trim()}']`,
            });
        });
        result.menu_spans = spanItems;

        return result;
    });

    // Screenshot of dashboard with sidebar
    const screenshotPath = path.join(MEMORY_DIR, "screenshots", "dashboard-sidebar.png");
    await page.screenshot({ path: screenshotPath, fullPage: false });
    console.log("Sidebar screenshot saved.");

    console.log("Sidebar data:", JSON.stringify(sidebarData, null, 2));
    return sidebarData;
}

async function navigateAndCapturePage(page, menuItemText) {
    console.log(`\nNavigating to: ${menuItemText}`);

    try {
        // Click the menu item by text
        // Try various selector strategies
        const menuSelector = `.oxd-main-menu-item--name`;
        const menuItems = await page.locator(menuSelector).all();

        let clicked = false;
        for (const item of menuItems) {
            const text = await item.textContent();
            if (text && text.trim() === menuItemText) {
                await item.click();
                clicked = true;
                break;
            }
        }

        if (!clicked) {
            // Fallback: try clicking by link text
            await page.click(`text="${menuItemText}"`, { timeout: 5000 });
        }

        await sleep(3000);
        await page.waitForLoadState("domcontentloaded", { timeout: 10000 });

        const currentUrl = page.url();
        console.log(`  URL after navigation: ${currentUrl}`);

        // Capture page heading and content selectors
        const pageData = await page.evaluate(() => {
            const data = {};

            // Page header/title - OrangeHRM uses h6 for page titles typically
            const h6 = document.querySelector("h6");
            if (h6) {
                data.heading = {
                    css: "h6",
                    xpath: "//h6",
                    text: h6.textContent.trim(),
                };
            }

            // OrangeHRM page header container
            const header = document.querySelector(".oxd-topbar-header-breadcrumb") ||
                           document.querySelector("[class*='breadcrumb']") ||
                           document.querySelector(".oxd-layout-context");
            if (header) {
                const cls = Array.from(header.classList);
                data.header_container = {
                    css: cls.length ? `.${cls[0]}` : "header",
                    text: header.textContent.trim().substring(0, 100),
                };
            }

            // Main content area
            const main = document.querySelector(".oxd-layout-context") ||
                         document.querySelector("main") ||
                         document.querySelector(".main-content") ||
                         document.querySelector("[class*='content']");
            if (main) {
                const cls = Array.from(main.classList);
                data.main_content = {
                    css: cls.length ? `.${cls.join(".")}` : "main",
                    xpath: "//main | //div[contains(@class,'content')]",
                };
            }

            // Look for any data table
            const table = document.querySelector(".oxd-table") ||
                          document.querySelector("table") ||
                          document.querySelector("[class*='table']");
            if (table) {
                const cls = Array.from(table.classList);
                data.data_table = {
                    css: cls.length ? `.${cls[0]}` : "table",
                    visible: true,
                };
            }

            // Page-specific widgets (cards, dashboards)
            const widgets = document.querySelectorAll(".orangehrm-dashboard-widget, [class*='widget'], [class*='card']");
            if (widgets.length > 0) {
                data.widgets = {
                    count: widgets.length,
                    css: `.${Array.from(widgets[0].classList)[0]}`,
                };
            }

            return data;
        });

        // Screenshot
        const safeMenuName = menuItemText.toLowerCase().replace(/\s+/g, "-");
        const screenshotPath = path.join(MEMORY_DIR, "screenshots", `${safeMenuName}.png`);
        await page.screenshot({ path: screenshotPath, fullPage: false });

        return {
            menu_item: menuItemText,
            url: currentUrl,
            selectors: pageData,
            screenshot: `screenshots/${safeMenuName}.png`,
        };
    } catch (err) {
        console.error(`  Error navigating to ${menuItemText}:`, err.message);
        return {
            menu_item: menuItemText,
            url: page.url(),
            error: err.message,
            selectors: {},
        };
    }
}

async function main() {
    console.log("Starting OrangeHRM selector exploration...");

    const browser = await chromium.launch({
        headless: true,
        args: ["--no-sandbox", "--disable-setuid-sandbox"],
    });

    const context = await browser.newContext({
        viewport: { width: 1280, height: 720 },
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    });

    const page = await context.newPage();

    // Collect all data
    const explorationData = {
        run_id: "GP-20260416-142117",
        status: "completed",
        env: "staging",
        base_url: BASE_URL,
        tool_used: "playwright-headless",
        login_page: {},
        sidebar: {},
        pages: {},
        selectors: {},
        navigation_flow: [],
        screenshots: [],
        captured_values: {},
    };

    try {
        // Step 1: Capture login page
        const loginSelectors = await captureLoginPageSelectors(page);
        explorationData.login_page = {
            url: LOGIN_URL,
            selectors: loginSelectors,
        };
        explorationData.screenshots.push("screenshots/login.png");
        explorationData.navigation_flow.push({
            step: 1,
            action: "navigate",
            url: "/web/index.php/auth/login",
            screenshot: "screenshots/login.png",
        });

        // Step 2: Login
        await login(page);
        explorationData.captured_values.post_login_url = page.url();
        explorationData.captured_values.post_login_path = page.url().replace(BASE_URL, "");

        // Step 3: Capture sidebar on dashboard
        const sidebarData = await captureSidebarSelectors(page);
        explorationData.sidebar = sidebarData;
        explorationData.screenshots.push("screenshots/dashboard-sidebar.png");
        explorationData.navigation_flow.push({
            step: 2,
            action: "login_and_capture_sidebar",
            url: "/web/index.php/dashboard/index",
            screenshot: "screenshots/dashboard-sidebar.png",
        });

        // Step 4: Navigate to each menu item
        const pageResults = {};
        let stepNum = 3;
        for (const menuItem of MENU_ITEMS) {
            const result = await navigateAndCapturePage(page, menuItem);
            pageResults[menuItem] = result;
            explorationData.screenshots.push(result.screenshot || "");
            explorationData.navigation_flow.push({
                step: stepNum++,
                action: "navigate_menu",
                menu_item: menuItem,
                url: result.url,
                screenshot: result.screenshot,
            });
            await sleep(1000);
        }
        explorationData.pages = pageResults;

        // Step 5: Build unified selectors map
        // Login selectors
        if (loginSelectors.username) {
            explorationData.selectors.usernameInput = {
                css: loginSelectors.username.css,
                xpath: loginSelectors.username.xpath,
                data_testid: loginSelectors.username.data_testid,
                aria_label: loginSelectors.username.aria_label,
                text: loginSelectors.username.placeholder,
                page: "/web/index.php/auth/login",
                reuse_from: null,
            };
        }
        if (loginSelectors.password) {
            explorationData.selectors.passwordInput = {
                css: loginSelectors.password.css,
                xpath: loginSelectors.password.xpath,
                data_testid: loginSelectors.password.data_testid,
                aria_label: loginSelectors.password.aria_label,
                text: loginSelectors.password.placeholder,
                page: "/web/index.php/auth/login",
                reuse_from: null,
            };
        }
        if (loginSelectors.login_button) {
            explorationData.selectors.loginButton = {
                css: loginSelectors.login_button.css,
                xpath: loginSelectors.login_button.xpath,
                data_testid: loginSelectors.login_button.data_testid,
                aria_label: loginSelectors.login_button.aria_label,
                text: loginSelectors.login_button.text,
                page: "/web/index.php/auth/login",
                reuse_from: null,
            };
        }

        // Sidebar
        if (sidebarData.container) {
            explorationData.selectors.sidebarContainer = {
                css: sidebarData.container.css,
                xpath: sidebarData.container.xpath || "//nav",
                data_testid: null,
                aria_label: null,
                text: null,
                page: "all",
                reuse_from: null,
            };
        }

        // Menu items
        for (const item of MENU_ITEMS) {
            const safeName = `menuItem${item.replace(/\s+/g, "")}`;
            explorationData.selectors[safeName] = {
                css: `.oxd-main-menu-item--name`,
                xpath: `//span[contains(@class,'oxd-main-menu-item--name') and normalize-space(text())='${item}']`,
                data_testid: null,
                aria_label: null,
                text: item,
                page: "all",
                reuse_from: null,
            };
        }

        // Page headings
        for (const [menuItem, result] of Object.entries(pageResults)) {
            if (result.selectors && result.selectors.heading) {
                const safeName = `${menuItem.toLowerCase().replace(/\s+/g, "")}PageHeading`;
                explorationData.selectors[safeName] = {
                    css: result.selectors.heading.css,
                    xpath: result.selectors.heading.xpath,
                    data_testid: null,
                    aria_label: null,
                    text: result.selectors.heading.text,
                    page: result.url.replace(BASE_URL, ""),
                    reuse_from: null,
                };
            }
        }

        // Step 6: Also get actual HTML attributes for login page to confirm selectors
        await page.goto(LOGIN_URL, { waitUntil: "networkidle", timeout: 30000 });
        await sleep(2000);

        const loginPageHtml = await page.evaluate(() => {
            const inputs = document.querySelectorAll("input");
            const data = [];
            inputs.forEach((inp) => {
                data.push({
                    tagName: inp.tagName,
                    type: inp.type,
                    name: inp.name,
                    id: inp.id,
                    class: inp.className,
                    placeholder: inp.placeholder,
                    dataTestid: inp.getAttribute("data-testid"),
                    ariaLabel: inp.getAttribute("aria-label"),
                    autocomplete: inp.getAttribute("autocomplete"),
                });
            });

            const buttons = document.querySelectorAll("button");
            const btnData = [];
            buttons.forEach((btn) => {
                btnData.push({
                    tagName: btn.tagName,
                    type: btn.type,
                    class: btn.className,
                    text: btn.textContent.trim(),
                    dataTestid: btn.getAttribute("data-testid"),
                    ariaLabel: btn.getAttribute("aria-label"),
                });
            });

            return { inputs: data, buttons: btnData };
        });

        explorationData.login_page_raw_elements = loginPageHtml;
        console.log("\nLogin page raw elements:", JSON.stringify(loginPageHtml, null, 2));

    } catch (err) {
        console.error("Exploration error:", err.message);
        explorationData.status = "partial";
        explorationData.error = err.message;
    } finally {
        await browser.close();
    }

    // Write browser-data.json
    const outputPath = path.join(MEMORY_DIR, "browser-data.json");
    fs.writeFileSync(outputPath, JSON.stringify(explorationData, null, 2));
    console.log(`\nbrowser-data.json written to: ${outputPath}`);

    // Write orangehrm.json selectors config
    fs.mkdirSync(SELECTORS_DIR, { recursive: true });
    const orangehrmSelectors = buildOrangeHRMSelectors(explorationData);
    const selectorsPath = path.join(SELECTORS_DIR, "orangehrm.json");
    fs.writeFileSync(selectorsPath, JSON.stringify(orangehrmSelectors, null, 2));
    console.log(`orangehrm.json written to: ${selectorsPath}`);

    return explorationData;
}

function buildOrangeHRMSelectors(data) {
    const selectors = {
        _meta: {
            app: "OrangeHRM",
            base_url: "https://opensource-demo.orangehrmlive.com",
            captured_at: new Date().toISOString(),
            run_id: data.run_id,
        },
        login: {
            page_url: "/web/index.php/auth/login",
            username_input: "input[name='username']",
            password_input: "input[name='password']",
            login_button: "button[type='submit']",
            login_form: ".orangehrm-login-form",
            login_container: ".orangehrm-login-container",
        },
        sidebar: {
            container: ".oxd-sidepanel",
            main_menu: ".oxd-main-menu",
            menu_item: ".oxd-main-menu-item",
            menu_item_text: ".oxd-main-menu-item--name",
            menu_item_active: ".oxd-main-menu-item.active",
        },
        navigation: {},
        pages: {},
    };

    // Navigation menu items
    for (const item of MENU_ITEMS) {
        const key = item.toLowerCase().replace(/\s+/g, "_");
        selectors.navigation[key] = {
            menu_text_selector: `.oxd-main-menu-item--name`,
            xpath: `//span[contains(@class,'oxd-main-menu-item--name') and normalize-space(text())='${item}']`,
            text: item,
        };
    }

    // Per-page selectors
    if (data.pages) {
        for (const [menuItem, pageData] of Object.entries(data.pages)) {
            const key = menuItem.toLowerCase().replace(/\s+/g, "_");
            selectors.pages[key] = {
                url: pageData.url || "",
                url_pattern: pageData.url ? pageData.url.replace("https://opensource-demo.orangehrmlive.com", "") : "",
            };
            if (pageData.selectors) {
                if (pageData.selectors.heading) {
                    selectors.pages[key].page_heading = {
                        css: pageData.selectors.heading.css,
                        xpath: pageData.selectors.heading.xpath,
                        expected_text: pageData.selectors.heading.text,
                    };
                }
                if (pageData.selectors.main_content) {
                    selectors.pages[key].main_content = pageData.selectors.main_content.css;
                }
                if (pageData.selectors.data_table) {
                    selectors.pages[key].data_table = pageData.selectors.data_table.css;
                }
            }
        }
    }

    return selectors;
}

main().then((data) => {
    console.log("\n=== EXPLORATION COMPLETE ===");
    console.log(`Selectors captured: ${Object.keys(data.selectors || {}).length}`);
    console.log(`Pages explored: ${Object.keys(data.pages || {}).length}`);
    console.log(`Screenshots: ${(data.screenshots || []).length}`);
}).catch((err) => {
    console.error("Fatal error:", err);
    process.exit(1);
});
