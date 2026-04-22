#!/usr/bin/env bash
# browser-strategy.sh
# Adaptive browser automation strategy that selects the best browser tool
# based on the testing framework and available infrastructure.
#
# Usage:
#   source scripts/browser-strategy.sh
#   detect_browser_tier [framework_id]
#
# Output: Sets BROWSER_TIER, BROWSER_TOOL, and BROWSER_FALLBACK env vars.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Tier 1: Claude-in-Chrome (MCP extension) ────────────────────────────────
# Available only to the lead agent when Chrome extension is connected.
# Shares browser login state — no separate auth needed.

check_tier1() {
    # claude-in-chrome is available when the MCP chrome extension is connected
    # Check via process or environment flag
    if [ "${CLAUDE_CHROME_CONNECTED:-}" = "1" ] || [ "${CHROME_EXTENSION:-}" = "1" ]; then
        return 0
    fi
    return 1
}

# ── Tier 2: Chrome CDP (persistent sessions) ────────────────────────────────
# Primary tool for subagents. Sessions persist across agents.

check_tier2() {
    # Check for CDP port file or running Chrome with remote debugging
    local cdp_port_file="${CDP_PORT_FILE:-}"
    if [ -n "$cdp_port_file" ] && [ -f "$cdp_port_file" ]; then
        local port
        port=$(cat "$cdp_port_file" 2>/dev/null)
        if [ -n "$port" ] && curl -sf "http://localhost:${port}/json/version" > /dev/null 2>&1; then
            return 0
        fi
    fi

    # Try common CDP ports
    for port in 9222 9223 9224; do
        if curl -sf "http://localhost:${port}/json/version" > /dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}

# ── Tier 3: Framework-Specific (dynamic based on selected framework) ────────
# Adapts based on the user's chosen testing framework.

get_tier3_tool() {
    local framework="${1:-playwright-js}"

    case "$framework" in
        playwright-js|playwright-typescript|playwright-python)
            echo "playwright-cli"
            ;;
        cypress-js)
            echo "cypress-runner"
            ;;
        selenium-python|selenium-java)
            echo "selenium-webdriver"
            ;;
        puppeteer-js)
            echo "puppeteer-scripts"
            ;;
        testcafe-js)
            echo "testcafe-runner"
            ;;
        webdriverio-js)
            echo "webdriverio-cli"
            ;;
        appium-python|appium-java)
            echo "appium-client"
            ;;
        robot-framework)
            echo "robotframework-browser"
            ;;
        *)
            # Default fallback is always Playwright
            echo "playwright-cli"
            ;;
    esac
}

get_tier3_fallback() {
    local framework="${1:-playwright-js}"
    local primary
    primary=$(get_tier3_tool "$framework")

    # If the primary tool IS Playwright, no fallback needed
    if [ "$primary" = "playwright-cli" ]; then
        echo "none"
        return
    fi

    # Everything else falls back to Playwright as universal option
    echo "playwright-cli"
}

# ── Detection Order ──────────────────────────────────────────────────────────
# Lead agent: Tier 1 → Tier 2 → Tier 3
# Subagents:  Tier 2 → Tier 3

detect_browser_tier() {
    local framework="${1:-${GP_FRAMEWORK:-playwright-js}}"
    local is_lead="${2:-false}"

    # Tier 1: claude-in-chrome (lead agent only)
    if [ "$is_lead" = "true" ] && check_tier1; then
        export BROWSER_TIER="1"
        export BROWSER_TOOL="claude-in-chrome"
        export BROWSER_FALLBACK="cdp"
        echo '{"tier":1,"tool":"claude-in-chrome","fallback":"cdp","framework":"'"$framework"'"}'
        return 0
    fi

    # Tier 2: Chrome CDP
    if check_tier2; then
        export BROWSER_TIER="2"
        export BROWSER_TOOL="cdp"
        export BROWSER_FALLBACK=$(get_tier3_tool "$framework")
        echo '{"tier":2,"tool":"cdp","fallback":"'"$(get_tier3_tool "$framework")"'","framework":"'"$framework"'"}'
        return 0
    fi

    # Tier 3: Framework-specific
    local tool
    tool=$(get_tier3_tool "$framework")
    local fallback
    fallback=$(get_tier3_fallback "$framework")

    export BROWSER_TIER="3"
    export BROWSER_TOOL="$tool"
    export BROWSER_FALLBACK="$fallback"
    echo '{"tier":3,"tool":"'"$tool"'","fallback":"'"$fallback"'","framework":"'"$framework"'"}'
    return 0
}

# ── Launch Browser for Framework ─────────────────────────────────────────────

launch_browser_for_framework() {
    local framework="${1:-playwright-js}"
    local url="${2:-${STAGING_URL:-http://localhost:3000}}"
    local headless="${3:-${HEADLESS:-true}}"

    case "$framework" in
        playwright-js|playwright-typescript)
            local headed_flag=""
            if [ "$headless" = "false" ]; then headed_flag="--headed"; fi
            echo "npx playwright open $headed_flag \"$url\""
            ;;
        playwright-python)
            echo "python -m playwright open \"$url\""
            ;;
        cypress-js)
            echo "npx cypress open --e2e"
            ;;
        selenium-python)
            echo "python -c \"from selenium import webdriver; d=webdriver.Chrome(); d.get('$url')\""
            ;;
        puppeteer-js)
            echo "node -e \"const p=require('puppeteer');(async()=>{const b=await p.launch({headless:$headless});const pg=await b.newPage();await pg.goto('$url');})()\""
            ;;
        *)
            echo "npx playwright open \"$url\""
            ;;
    esac
}

# ── Main (when run directly) ─────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    FRAMEWORK="${1:-${GP_FRAMEWORK:-playwright-js}}"
    IS_LEAD="${2:-false}"

    echo "Detecting browser strategy for framework: $FRAMEWORK"
    echo ""

    RESULT=$(detect_browser_tier "$FRAMEWORK" "$IS_LEAD")
    echo "Result: $RESULT"
    echo ""
    echo "  Tier:     $BROWSER_TIER"
    echo "  Tool:     $BROWSER_TOOL"
    echo "  Fallback: $BROWSER_FALLBACK"
fi
