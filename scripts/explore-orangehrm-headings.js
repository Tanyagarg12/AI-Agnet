/**
 * explore-orangehrm-headings.js
 * Supplementary script to capture page headings from each module after login.
 */

const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

const BASE_URL = "https://opensource-demo.orangehrmlive.com";
const LOGIN_URL = `${BASE_URL}/web/index.php/auth/login`;
const MEMORY_DIR = path.join(__dirname, "../memory/gp-runs/GP-20260416-142117");

const PAGES_TO_CHECK = [
    { name: "Admin", url: "/web/index.php/admin/viewSystemUsers" },
    { name: "PIM", url: "/web/index.php/pim/viewEmployeeList" },
    { name: "Leave", url: "/web/index.php/leave/viewLeaveList" },
    { name: "Time", url: "/web/index.php/time/viewEmployeeTimesheet" },
    { name: "Recruitment", url: "/web/index.php/recruitment/viewCandidates" },
    { name: "My Info", url: "/web/index.php/pim/viewPersonalDetails/empNumber/7" },
    { name: "Performance", url: "/web/index.php/performance/searchEvaluatePerformanceReview" },
    { name: "Dashboard", url: "/web/index.php/dashboard/index" },
    { name: "Directory", url: "/web/index.php/directory/viewDirectory" },
];

async function sleep(ms) {
    return new Promise((r) => setTimeout(r, ms));
}

async function main() {
    const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
    const context = await browser.newContext({ viewport: { width: 1280, height: 720 } });
    const page = await context.newPage();

    // Login
    await page.goto(LOGIN_URL, { waitUntil: "networkidle", timeout: 30000 });
    await sleep(1000);
    await page.fill("input[name='username']", "Admin");
    await page.fill("input[name='password']", "admin123");
    await page.click("button[type='submit']");
    await page.waitForURL("**/dashboard/**", { timeout: 15000 });
    await sleep(2000);
    console.log("Logged in successfully.");

    const results = {};

    for (const pageInfo of PAGES_TO_CHECK) {
        console.log(`\nChecking: ${pageInfo.name} (${pageInfo.url})`);
        await page.goto(`${BASE_URL}${pageInfo.url}`, { waitUntil: "domcontentloaded", timeout: 15000 });
        await sleep(2500);

        const data = await page.evaluate(() => {
            const result = {};

            // Try h6 (OrangeHRM page titles are typically in h6)
            const h6Elements = Array.from(document.querySelectorAll("h6"));
            result.h6_texts = h6Elements.map((el) => el.textContent.trim()).filter(Boolean);

            // Try .oxd-topbar-header-breadcrumb
            const breadcrumb = document.querySelector(".oxd-topbar-header-breadcrumb");
            if (breadcrumb) {
                result.breadcrumb_text = breadcrumb.textContent.trim();
                result.breadcrumb_css = ".oxd-topbar-header-breadcrumb";
            }

            // Page header text
            const header = document.querySelector(".oxd-layout-context h6") ||
                           document.querySelector(".orangehrm-header-container h6") ||
                           document.querySelector(".oxd-table-filter h6") ||
                           document.querySelector("h6");
            if (header) {
                result.main_heading = {
                    text: header.textContent.trim(),
                    css: "h6",
                    xpath: "//h6",
                };
            }

            // Look for topbar title
            const topbarTitle = document.querySelector(".oxd-topbar-header-title") ||
                                 document.querySelector(".oxd-topbar-header h6");
            if (topbarTitle) {
                result.topbar_title = topbarTitle.textContent.trim();
            }

            // Table present?
            const table = document.querySelector(".oxd-table");
            result.has_table = !!table;

            // Cards / widgets
            const widgets = document.querySelectorAll(".orangehrm-dashboard-widget");
            result.widget_count = widgets.length;
            if (widgets.length > 0) {
                result.widget_selector = ".orangehrm-dashboard-widget";
                const widgetTitles = Array.from(widgets).map((w) => {
                    const t = w.querySelector("h6, .widget-title, [class*='title']");
                    return t ? t.textContent.trim() : "";
                }).filter(Boolean);
                result.widget_titles = widgetTitles;
            }

            // Content container
            const content = document.querySelector(".oxd-layout-context");
            if (content) {
                result.content_container = ".oxd-layout-context";
            }

            return result;
        });

        results[pageInfo.name] = {
            url: page.url(),
            captured: data,
        };

        console.log(`  h6 texts: ${JSON.stringify(data.h6_texts)}`);
        console.log(`  breadcrumb: ${data.breadcrumb_text || "none"}`);
        console.log(`  main_heading: ${JSON.stringify(data.main_heading)}`);
        console.log(`  has_table: ${data.has_table}`);
        if (data.widget_count > 0) {
            console.log(`  widgets: ${data.widget_count}, titles: ${JSON.stringify(data.widget_titles)}`);
        }
    }

    await browser.close();

    // Save headings data
    const outputPath = path.join(MEMORY_DIR, "page-headings.json");
    fs.writeFileSync(outputPath, JSON.stringify(results, null, 2));
    console.log(`\nPage headings saved to: ${outputPath}`);

    return results;
}

main().catch((err) => {
    console.error("Error:", err);
    process.exit(1);
});
