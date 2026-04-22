#!/usr/bin/env bash
# gp-detect-framework.sh
# Auto-detects the test framework from existing project files.
# Usage: ./scripts/gp-detect-framework.sh [project_path]
# Outputs: framework_id (e.g., playwright-js, selenium-python, cypress-js)

set -euo pipefail

PROJECT_PATH="${1:-.}"

detect_from_signals() {
    local path="$1"

    # Check package.json for JS/TS frameworks
    if [ -f "${path}/package.json" ]; then
        if python3 -c "
import json, sys
pkg = json.load(open('${path}/package.json'))
deps = {**pkg.get('dependencies', {}), **pkg.get('devDependencies', {})}
if '@playwright/test' in deps: print('playwright-js'); sys.exit(0)
if 'playwright' in deps and 'typescript' in deps: print('playwright-typescript'); sys.exit(0)
if 'playwright' in deps: print('playwright-js'); sys.exit(0)
if 'cypress' in deps: print('cypress-js'); sys.exit(0)
if 'webdriverio' in deps: print('webdriverio-js'); sys.exit(0)
" 2>/dev/null; then
            return 0
        fi
    fi

    # Check for TypeScript Playwright config
    if [ -f "${path}/playwright.config.ts" ]; then
        echo "playwright-typescript"
        return 0
    fi

    # Check for JS Playwright config
    if [ -f "${path}/playwright.config.js" ]; then
        echo "playwright-js"
        return 0
    fi

    # Check for Cypress
    if [ -f "${path}/cypress.config.js" ] || [ -f "${path}/cypress.config.ts" ]; then
        echo "cypress-js"
        return 0
    fi

    # Check Python requirements
    for req_file in "${path}/requirements.txt" "${path}/Pipfile" "${path}/pyproject.toml"; do
        if [ -f "${req_file}" ]; then
            if grep -qi "pytest-playwright" "${req_file}" 2>/dev/null; then
                echo "playwright-python"
                return 0
            fi
            if grep -qi "Appium-Python-Client\|appium" "${req_file}" 2>/dev/null; then
                echo "appium-python"
                return 0
            fi
            if grep -qi "^selenium" "${req_file}" 2>/dev/null; then
                echo "selenium-python"
                return 0
            fi
            if grep -qi "robotframework" "${req_file}" 2>/dev/null; then
                echo "robot-framework"
                return 0
            fi
        fi
    done

    # Check for Robot Framework
    if ls "${path}"/*.robot "${path}/tests"/*.robot 2>/dev/null | head -1 | grep -q ".robot"; then
        echo "robot-framework"
        return 0
    fi

    # Check Java pom.xml
    if [ -f "${path}/pom.xml" ]; then
        if grep -q "appium" "${path}/pom.xml" 2>/dev/null; then
            echo "appium-java"
            return 0
        fi
        if grep -qi "selenium" "${path}/pom.xml" 2>/dev/null; then
            echo "selenium-java"
            return 0
        fi
    fi

    # Check Gradle
    if [ -f "${path}/build.gradle" ]; then
        if grep -qi "selenium" "${path}/build.gradle" 2>/dev/null; then
            echo "selenium-java"
            return 0
        fi
    fi

    # No detection — use default
    DEFAULT=$(python3 -c "
import json
try:
    with open('config/gp-defaults.json') as f:
        print(json.load(f).get('default_framework', 'playwright-js'))
except:
    print('playwright-js')
" 2>/dev/null || echo "playwright-js")

    echo "${DEFAULT}"
    return 0
}

detect_from_signals "${PROJECT_PATH}"
