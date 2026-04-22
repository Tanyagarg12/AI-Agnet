#!/usr/bin/env bash
# detect-framework-interactive.sh
# Enhanced framework detection with interactive user prompts.
# Analyzes project folder, detects frameworks, shows results, and lets user choose.
#
# Usage:
#   ./scripts/detect-framework-interactive.sh [project_path]
#
# Output: Prints ONLY the selected framework ID to stdout (e.g., "playwright-js")
#         All display/UI text goes to /dev/tty
# Exit code: 0 on success, 1 on cancel

set -euo pipefail

PROJECT_PATH="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── ALL display goes to /dev/tty (or stderr), ONLY framework ID to stdout ────
# This is critical: the caller captures stdout via $(), so we must keep it clean.
if [ -e /dev/tty ] && [ -t 0 ]; then
    TTY=/dev/tty
else
    TTY=/dev/stderr
fi

print_header() {
    echo "" > "$TTY"
    echo "---------------------------------------------" > "$TTY"
    echo "  $1" > "$TTY"
    echo "---------------------------------------------" > "$TTY"
    echo "" > "$TTY"
}

print_info()    { echo "  [i] $1" > "$TTY"; }
print_success() { echo "  [+] $1" > "$TTY"; }
print_warn()    { echo "  [!] $1" > "$TTY"; }
print_error()   { echo "  [x] $1" > "$TTY"; }

# ── Step 1: Validate folder ─────────────────────────────────────────────────

print_header "Framework Detection"

if [ ! -d "$PROJECT_PATH" ]; then
    print_error "Folder not found: $PROJECT_PATH"
    exit 1
fi

print_info "Analyzing: $PROJECT_PATH"
echo "" > "$TTY"

# ── Step 2: Check for package.json ──────────────────────────────────────────

DETECTED=()
DETECTED_LABELS=()

if [ -f "$PROJECT_PATH/package.json" ]; then
    print_success "Found package.json -- scanning dependencies..."
    echo "" > "$TTY"

    # Parse package.json for testing frameworks (using node, works on all platforms)
    SCAN_RESULT=$(node -e "
const pkg = require('${PROJECT_PATH}/package.json');
const deps = Object.assign({}, pkg.dependencies, pkg.devDependencies);
const fw = [];

if (deps['@playwright/test']) {
    if (deps['typescript'] || Object.keys(deps).some(k => k.startsWith('@types/')))
        fw.push('playwright-typescript|Playwright (TypeScript)|' + deps['@playwright/test']);
    else
        fw.push('playwright-js|Playwright (JavaScript)|' + deps['@playwright/test']);
} else if (deps['playwright']) {
    fw.push('playwright-js|Playwright (JavaScript)|' + deps['playwright']);
}

if (deps['cypress']) fw.push('cypress-js|Cypress (JavaScript)|' + deps['cypress']);
if (deps['webdriverio'] || deps['@wdio/cli']) fw.push('webdriverio-js|WebdriverIO|' + (deps['webdriverio'] || deps['@wdio/cli']));
if (deps['jest'] && (deps['@testing-library/react'] || deps['jest-puppeteer'])) fw.push('jest-ui|Jest (UI Testing)|' + deps['jest']);
if (deps['puppeteer'] || deps['puppeteer-core']) fw.push('puppeteer-js|Puppeteer|' + (deps['puppeteer'] || deps['puppeteer-core']));
if (deps['testcafe']) fw.push('testcafe-js|TestCafe|' + deps['testcafe']);
if (deps['mocha'] && (deps['selenium-webdriver'] || deps['webdriverio'])) fw.push('mocha-selenium|Mocha + Selenium|' + deps['mocha']);

fw.forEach(f => console.log(f));
" 2>/dev/null) || SCAN_RESULT=""

    if [ -n "$SCAN_RESULT" ]; then
        while IFS='|' read -r fw_id fw_label fw_ver; do
            DETECTED+=("$fw_id")
            DETECTED_LABELS+=("$fw_label (v${fw_ver})")
            print_success "  Found: $fw_label v$fw_ver"
        done <<< "$SCAN_RESULT"
    fi

    if [ -f "$PROJECT_PATH/requirements.txt" ]; then
        print_info "Also found requirements.txt (Python dependencies)"
        if grep -qi "pytest-playwright" "$PROJECT_PATH/requirements.txt" 2>/dev/null; then
            DETECTED+=("playwright-python"); DETECTED_LABELS+=("Playwright (Python)")
            print_success "  Found: Playwright (Python)"
        fi
        if grep -qi "^selenium" "$PROJECT_PATH/requirements.txt" 2>/dev/null; then
            DETECTED+=("selenium-python"); DETECTED_LABELS+=("Selenium (Python)")
            print_success "  Found: Selenium (Python)"
        fi
    fi

else
    print_warn "No package.json found"

    for req_file in "$PROJECT_PATH/requirements.txt" "$PROJECT_PATH/Pipfile" "$PROJECT_PATH/pyproject.toml"; do
        if [ -f "$req_file" ]; then
            print_info "Found $(basename "$req_file") -- checking Python frameworks..."
            if grep -qi "pytest-playwright" "$req_file" 2>/dev/null; then
                DETECTED+=("playwright-python"); DETECTED_LABELS+=("Playwright (Python)")
                print_success "  Found: Playwright (Python)"
            fi
            if grep -qi "^selenium" "$req_file" 2>/dev/null; then
                DETECTED+=("selenium-python"); DETECTED_LABELS+=("Selenium (Python)")
                print_success "  Found: Selenium (Python)"
            fi
            if grep -qi "Appium-Python-Client\|appium" "$req_file" 2>/dev/null; then
                DETECTED+=("appium-python"); DETECTED_LABELS+=("Appium (Python)")
                print_success "  Found: Appium (Python)"
            fi
            if grep -qi "robotframework" "$req_file" 2>/dev/null; then
                DETECTED+=("robot-framework"); DETECTED_LABELS+=("Robot Framework")
                print_success "  Found: Robot Framework"
            fi
            break
        fi
    done

    if [ -f "$PROJECT_PATH/pom.xml" ]; then
        print_info "Found pom.xml -- checking Java frameworks..."
        if grep -qi "appium" "$PROJECT_PATH/pom.xml" 2>/dev/null; then
            DETECTED+=("appium-java"); DETECTED_LABELS+=("Appium (Java)")
            print_success "  Found: Appium (Java)"
        fi
        if grep -qi "selenium" "$PROJECT_PATH/pom.xml" 2>/dev/null; then
            DETECTED+=("selenium-java"); DETECTED_LABELS+=("Selenium (Java)")
            print_success "  Found: Selenium (Java)"
        fi
    fi

    if [ -f "$PROJECT_PATH/playwright.config.ts" ]; then
        DETECTED+=("playwright-typescript"); DETECTED_LABELS+=("Playwright (TypeScript)")
        print_success "  Found: Playwright (TypeScript) (config file)"
    elif [ -f "$PROJECT_PATH/playwright.config.js" ]; then
        DETECTED+=("playwright-js"); DETECTED_LABELS+=("Playwright (JavaScript)")
        print_success "  Found: Playwright (JavaScript) (config file)"
    fi
    if [ -f "$PROJECT_PATH/cypress.config.js" ] || [ -f "$PROJECT_PATH/cypress.config.ts" ]; then
        DETECTED+=("cypress-js"); DETECTED_LABELS+=("Cypress (JavaScript)")
        print_success "  Found: Cypress (JavaScript) (config file)"
    fi

    if ls "$PROJECT_PATH"/*.robot "$PROJECT_PATH/tests"/*.robot 2>/dev/null | head -1 | grep -q ".robot" 2>/dev/null; then
        DETECTED+=("robot-framework"); DETECTED_LABELS+=("Robot Framework")
        print_success "  Found: Robot Framework (.robot files)"
    fi
fi

echo "" > "$TTY"

# ── Step 3: Show detection summary ──────────────────────────────────────────

NUM_DETECTED=${#DETECTED[@]}

if [ "$NUM_DETECTED" -eq 0 ]; then
    print_warn "No testing framework detected in this project."
    echo "" > "$TTY"
    echo "  The project does not appear to have any testing framework installed." > "$TTY"
    echo "" > "$TTY"
fi

# ── Step 4: Ask user what to do ─────────────────────────────────────────────

if [ "$NUM_DETECTED" -gt 0 ]; then
    echo "  What would you like to do?" > "$TTY"
    echo "" > "$TTY"

    if [ "$NUM_DETECTED" -eq 1 ]; then
        echo "    1)  Use ${DETECTED_LABELS[0]} (detected)" > "$TTY"
    else
        echo "    1)  Choose from detected frameworks:" > "$TTY"
        for i in "${!DETECTED_LABELS[@]}"; do
            echo "        $((i+1)). ${DETECTED_LABELS[$i]}" > "$TTY"
        done
    fi
    echo "    2)  Choose a different framework" > "$TTY"
    echo "    3)  Initialize a new framework setup" > "$TTY"
    echo "" > "$TTY"
    if [ -e /dev/tty ] && [ -t 0 ]; then
        read -rp "  Enter choice (1-3) [1]: " USER_CHOICE < /dev/tty
    else
        read -rp "  Enter choice (1-3) [1]: " USER_CHOICE 2>/dev/null || USER_CHOICE=""
    fi
    USER_CHOICE="${USER_CHOICE:-1}"

    case "$USER_CHOICE" in
        1)
            if [ "$NUM_DETECTED" -eq 1 ]; then
                echo "${DETECTED[0]}"
                exit 0
            else
                echo "" > "$TTY"
                echo "  Select detected framework:" > "$TTY"
                echo "" > "$TTY"
                for i in "${!DETECTED[@]}"; do
                    echo "    $((i+1)))  ${DETECTED_LABELS[$i]}" > "$TTY"
                done
                echo "" > "$TTY"
                if [ -e /dev/tty ] && [ -t 0 ]; then
                    read -rp "  Enter number [1]: " FW_NUM < /dev/tty
                else
                    read -rp "  Enter number [1]: " FW_NUM 2>/dev/null || FW_NUM=""
                fi
                FW_NUM="${FW_NUM:-1}"
                IDX=$((FW_NUM - 1))
                if [ "$IDX" -ge 0 ] && [ "$IDX" -lt "$NUM_DETECTED" ]; then
                    echo "${DETECTED[$IDX]}"
                    exit 0
                else
                    print_error "Invalid selection"
                    exit 1
                fi
            fi
            ;;
        2|3)
            # Fall through to full framework selection
            ;;
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
else
    HAS_NODE=false
    [ -f "$PROJECT_PATH/package.json" ] && HAS_NODE=true

    if [ "$HAS_NODE" = false ]; then
        echo "  What would you like to do?" > "$TTY"
        echo "" > "$TTY"
        echo "    1)  Initialize Node.js + testing framework" > "$TTY"
        echo "    2)  Use non-Node framework (Python, Java, Robot)" > "$TTY"
        echo "    3)  Cancel" > "$TTY"
        echo "" > "$TTY"
        if [ -e /dev/tty ] && [ -t 0 ]; then
            read -rp "  Enter choice (1-3): " NO_NODE_CHOICE < /dev/tty
        else
            read -rp "  Enter choice (1-3): " NO_NODE_CHOICE 2>/dev/null || NO_NODE_CHOICE=""
        fi

        case "$NO_NODE_CHOICE" in
            1|2)
                # Fall through to full framework selection
                ;;
            3|*)
                print_info "Setup cancelled."
                exit 1
                ;;
        esac
    fi
fi

# ── Step 5: Full framework selection menu ────────────────────────────────────

print_header "Choose a Testing Framework"

cat > "$TTY" <<'MENU'
     1)  Playwright (JavaScript)       -- Recommended
         Best for: Modern web apps, API testing, cross-browser
         Setup: Easy  |  Community: Large  |  Auto-wait built-in

     2)  Playwright (TypeScript)
         Best for: Type-safe test suites, large teams
         Setup: Easy  |  Adds type checking to Playwright

     3)  Playwright (Python)
         Best for: Python-centric teams, pytest integration
         Setup: Easy  |  Full pytest ecosystem

     4)  Cypress (JavaScript)
         Best for: Component testing, visual testing, SPAs
         Setup: Easy  |  Real-time reload  |  Chromium-only

     5)  Selenium (Python)
         Best for: Cross-browser, legacy apps, widespread adoption
         Setup: Medium  |  Largest ecosystem  |  WebDriver protocol

     6)  Selenium (Java + TestNG)
         Best for: Enterprise Java teams, CI/CD pipelines
         Setup: Medium  |  Maven/Gradle  |  Parallel execution

     7)  Puppeteer (JavaScript)
         Best for: Chrome-specific automation, scraping, PDFs
         Setup: Easy  |  Chrome DevTools Protocol  |  Low-level control

     8)  TestCafe (JavaScript)
         Best for: No WebDriver needed, proxy-based, simple setup
         Setup: Easy  |  Built-in assertions  |  Cross-browser

     9)  Appium (Python) -- Mobile
         Best for: Android/iOS native and hybrid apps
         Setup: Complex  |  Requires emulator/device

    10)  Appium (Java) -- Mobile
         Best for: Enterprise mobile testing, Java teams
         Setup: Complex  |  Maven  |  Appium server required

    11)  Robot Framework
         Best for: Keyword-driven testing, non-developers, BDD
         Setup: Medium  |  Natural language syntax

MENU

echo "" > "$TTY"
echo "  Select the testing framework by entering its number:" > "$TTY"

if [ -e /dev/tty ] && [ -t 0 ]; then
    read -rp "  Enter number (1-11) [1]: " FW_CHOICE < /dev/tty
else
    read -rp "  Enter number (1-11) [1]: " FW_CHOICE 2>/dev/null || FW_CHOICE=""
fi
FW_CHOICE="${FW_CHOICE:-1}"

case "$FW_CHOICE" in
    1)  echo "playwright-js" ;;
    2)  echo "playwright-typescript" ;;
    3)  echo "playwright-python" ;;
    4)  echo "cypress-js" ;;
    5)  echo "selenium-python" ;;
    6)  echo "selenium-java" ;;
    7)  echo "puppeteer-js" ;;
    8)  echo "testcafe-js" ;;
    9)  echo "appium-python" ;;
    10) echo "appium-java" ;;
    11) echo "robot-framework" ;;
    *)
        echo "  Invalid choice. Defaulting to Playwright (JavaScript)." > "$TTY"
        echo "playwright-js"
        ;;
esac
