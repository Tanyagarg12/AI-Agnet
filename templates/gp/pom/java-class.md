# Java Page Object Model Template

Use for Selenium WebDriver (Java + TestNG) and Appium (Java).

## BasePage (create once per project)

```java
// src/test/java/com/tests/pages/BasePage.java
package com.tests.pages;

import com.google.gson.Gson;
import com.google.gson.reflect.TypeToken;
import org.openqa.selenium.*;
import org.openqa.selenium.support.ui.*;
import java.io.FileReader;
import java.time.Duration;
import java.util.Map;

public class BasePage {
    protected WebDriver driver;
    protected WebDriverWait wait;
    protected Map<String, String> selectors;
    private static final int WAIT_TIMEOUT = Integer.parseInt(
        System.getenv().getOrDefault("WAIT_TIMEOUT", "10")
    );

    public BasePage(WebDriver driver, String selectorFile) {
        this.driver = driver;
        this.wait = new WebDriverWait(driver, Duration.ofSeconds(WAIT_TIMEOUT));
        this.selectors = loadSelectors(selectorFile);
    }

    protected Map<String, String> loadSelectors(String feature) {
        try (FileReader reader = new FileReader("config/selectors/" + feature + ".json")) {
            return new Gson().fromJson(reader, new TypeToken<Map<String, String>>(){}.getType());
        } catch (Exception e) {
            throw new RuntimeException("Failed to load selectors: " + feature, e);
        }
    }

    protected void clickElement(String xpathKey) {
        WebElement el = wait.until(
            ExpectedConditions.elementToBeClickable(By.xpath(selectors.get(xpathKey)))
        );
        el.click();
    }

    protected void fillInput(String xpathKey, String value) {
        WebElement el = wait.until(
            ExpectedConditions.visibilityOfElementLocated(By.xpath(selectors.get(xpathKey)))
        );
        el.clear();
        el.sendKeys(value);
    }

    protected String getText(String xpathKey) {
        WebElement el = wait.until(
            ExpectedConditions.visibilityOfElementLocated(By.xpath(selectors.get(xpathKey)))
        );
        return el.getText();
    }

    protected boolean isVisible(String xpathKey) {
        try {
            new WebDriverWait(driver, Duration.ofSeconds(5)).until(
                ExpectedConditions.visibilityOfElementLocated(By.xpath(selectors.get(xpathKey)))
            );
            return true;
        } catch (TimeoutException e) {
            return false;
        }
    }

    protected int getCount(String xpathKey) {
        return driver.findElements(By.xpath(selectors.get(xpathKey))).size();
    }

    protected void navigateTo(String url) {
        driver.get(url);
    }

    protected void takeScreenshot(String name) {
        TakesScreenshot ts = (TakesScreenshot) driver;
        byte[] screenshot = ts.getScreenshotAs(OutputType.BYTES);
        // Save to reports/screenshots/<name>.png
    }
}
```

## Feature Page Object

```java
// src/test/java/com/tests/pages/<FeatureName>Page.java
package com.tests.pages;

import org.openqa.selenium.WebDriver;
import org.openqa.selenium.support.ui.ExpectedConditions;
import org.openqa.selenium.By;

public class <FeatureName>Page extends BasePage {

    public <FeatureName>Page(WebDriver driver) {
        super(driver, "<feature>");
    }

    // Navigation
    public void navigateTo(String baseUrl) {
        super.navigateTo(baseUrl + "/<page-path>");
        wait.until(ExpectedConditions.visibilityOfElementLocated(
            By.xpath(selectors.get("mainContainer"))
        ));
    }

    // Actions — name after user intent
    public void click<Action>() {
        clickElement("<actionElement>");
    }

    public void fill<FieldName>(String value) {
        fillInput("<inputElement>", value);
    }

    public void select<FilterName>(String option) {
        clickElement("<filterTrigger>");
        clickElement("<filterOption>" + "[text()='" + option + "']");
    }

    // Getters — return typed values
    public int get<ItemCount>() {
        String text = getText("<counter>");
        return Integer.parseInt(text.trim().replace(",", ""));
    }

    public int get<TableRowCount>() {
        return getCount("<tableRow>");
    }

    public boolean is<ElementVisible>() {
        return isVisible("<element>");
    }
}
```

## BaseTest (TestNG setup/teardown)

```java
// src/test/java/com/tests/base/BaseTest.java
package com.tests.base;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import io.github.bonigarcia.wdm.WebDriverManager;
import org.openqa.selenium.WebDriver;
import org.openqa.selenium.chrome.ChromeDriver;
import org.openqa.selenium.chrome.ChromeOptions;
import org.testng.annotations.*;
import java.io.FileReader;

public class BaseTest {
    protected WebDriver driver;
    protected String baseUrl;
    protected String username;
    protected String password;

    @BeforeSuite
    public void loadConfig() throws Exception {
        String env = System.getenv().getOrDefault("TEST_ENV", "staging");
        JsonObject config = new Gson().fromJson(
            new FileReader("config/environments.json"), JsonObject.class
        ).getAsJsonObject(env);
        baseUrl = System.getenv().getOrDefault("BASE_URL", config.get("base_url").getAsString());
        username = System.getenv().getOrDefault("TEST_USER", config.get("username").getAsString());
        password = System.getenv().getOrDefault("TEST_PASSWORD", config.get("password").getAsString());
    }

    @BeforeMethod
    public void setUp() {
        WebDriverManager.chromedriver().setup();
        ChromeOptions options = new ChromeOptions();
        if (!"false".equals(System.getenv("HEADLESS"))) {
            options.addArguments("--headless=new");
        }
        options.addArguments("--no-sandbox", "--disable-dev-shm-usage", "--window-size=1920,1080");
        driver = new ChromeDriver(options);
        driver.manage().timeouts().implicitlyWait(java.time.Duration.ofSeconds(0));
    }

    @AfterMethod
    public void tearDown(org.testng.ITestResult result) {
        if (result.getStatus() == org.testng.ITestResult.FAILURE) {
            // Take screenshot
        }
        if (driver != null) driver.quit();
    }
}
```

## Rules for Generated Classes

1. Always extend `BasePage` — use protected methods, never raw `driver.findElement`
2. `PascalCase` for class names, `camelCase` for method names
3. Load selectors via `loadSelectors(feature)` — never hardcode XPath
4. Return types: `int`, `String`, `boolean` — never `WebElement` from public methods
5. `@BeforeMethod` + `@AfterMethod` for lifecycle in BaseTest — `@BeforeClass` only for shared state
6. Dependencies: `selenium-java`, `testng`, `webdrivermanager`, `gson`, `allure-testng` in pom.xml
