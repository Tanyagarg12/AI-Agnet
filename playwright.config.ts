import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright configuration for KAN-4 OrangeHRM navigation tests.
 * Credentials and URLs are loaded from environment variables — never hardcoded.
 */
export default defineConfig({
    testDir: "./tests",
    timeout: 30000,
    retries: 0,
    workers: 1,
    fullyParallel: false,
    reporter: [
        ["html", { outputFolder: "playwright-report" }],
        ["junit", { outputFile: "test-results/results.xml" }],
    ],
    use: {
        baseURL: process.env.STAGING_URL || "https://opensource-demo.orangehrmlive.com",
        headless: process.env.HEADLESS !== "false",
        trace: "on",
        screenshot: "only-on-failure",
        video: "retain-on-failure",
    },
    projects: [
        {
            name: "chromium",
            use: { ...devices["Desktop Chrome"] },
        },
    ],
});
