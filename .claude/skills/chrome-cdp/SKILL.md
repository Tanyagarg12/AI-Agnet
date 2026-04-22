---
name: chrome-cdp
description: Interact with Chrome browser via DevTools Protocol. Persistent sessions across agents. Use for browser exploration and debugging.
---

# Chrome CDP — Persistent Browser Sessions

**This is Tier 1 of the 3-tier browser tool hierarchy.** See below for the full detection order.

## 3-Tier Browser Tool Hierarchy

| Tier | Tool | Availability | Best For |
|------|------|-------------|----------|
| **0** | **`claude-in-chrome` MCP tools** | Lead agent only, when Chrome extension connected (`claude --chrome` or `/chrome`) | Lead-driven browser work (fix-pipeline Phase 3, quick inspections). Shares user's login, natural-language `find`. |
| **1** | **Chrome CDP** (this skill) | Subagents with Bash, when Chrome has remote debugging | Subagent primary tool. Persistent sessions across agent boundaries. |
| **2** | **`playwright-cli`** | Subagents with Bash, always works | Subagent fallback. Launches own browser, uses element refs. |

**Detection order for lead agent:**
1. Call `mcp__claude-in-chrome__tabs_context_mcp` — if it returns tabs, use `claude-in-chrome`
2. If error "No Chrome extension connected", fall through to CDP/playwright-cli

**Detection order for subagents (playwright-agent, debug-agent):**
Subagents only have Bash access — MCP tools are not available. Use CDP → playwright-cli.

## Prerequisites (Tier 1 — CDP)

- Chrome/Chromium with remote debugging enabled: `chrome://inspect/#remote-debugging`
- Node.js 22+
- Optional: `CDP_PORT_FILE` env var for custom Chrome location

## Commands

All commands use: `node .claude/skills/chrome-cdp/scripts/cdp.mjs <command> [args]`

| Command | Description | Example |
|---------|-------------|---------|
| `list` | List open tabs with targetId prefixes | `node cdp.mjs list` |
| `open <url>` | Open new tab (triggers permission dialog once) | `node cdp.mjs open "https://stg.app.ox.security"` |
| `nav <target> <url>` | Navigate existing tab to URL | `node cdp.mjs nav abc1 "/issues"` |
| `shot <target>` | Screenshot viewport | `node cdp.mjs shot abc1` |
| `snap <target>` | Accessibility tree snapshot (semantic DOM) | `node cdp.mjs snap abc1` |
| `click <target> <selector>` | Click element by CSS selector | `node cdp.mjs click abc1 "[data-testid='filter']"` |
| `clickxy <target> <x> <y>` | Click at coordinates | `node cdp.mjs clickxy abc1 100 200` |
| `type <target> <text>` | Type text into focused element | `node cdp.mjs type abc1 "hello"` |
| `eval <target> <expr>` | Execute JS in page context | `node cdp.mjs eval abc1 "document.title"` |
| `html <target> [selector]` | Get full HTML or scoped to selector | `node cdp.mjs html abc1 ".main"` |
| `net <target>` | Network resource timing | `node cdp.mjs net abc1` |
| `stop` | Terminate all daemons | `node cdp.mjs stop` |

## Session Lifecycle

- First access to a tab spawns a background daemon holding the WebSocket connection
- Chrome shows "Allow debugging" modal once per tab — subsequent commands are silent
- Daemons auto-terminate after 20 minutes of inactivity
- Use `stop` to clean up all daemons immediately

## Target IDs

`<target>` is a unique prefix from the `list` output. You only need enough characters to be unambiguous (e.g., `abc1` from `abc1234567`).

## Coordinate System

Screenshot pixels = CSS pixels x DPR. On Retina (DPR=2): divide screenshot coordinates by 2 for `clickxy`.

## Fallback: playwright-cli

If CDP connection fails (Chrome not running with `--remote-debugging-port`, `DevToolsActivePort` file missing), fall back to `playwright-cli`. Log the fallback in audit.md.

**Detection pattern** (use this at the start of every agent session):
```bash
CDP="node .claude/skills/chrome-cdp/scripts/cdp.mjs"
if $CDP list 2>/dev/null; then
    BROWSER_TOOL="cdp"
else
    echo "CDP unavailable — using playwright-cli"
    BROWSER_TOOL="playwright-cli"
fi
```

**Command mapping** (CDP → playwright-cli):

| CDP | playwright-cli | Notes |
|-----|----------------|-------|
| `$CDP open <url>` | `playwright-cli -s=<session> open <url>` | Opens browser |
| `$CDP nav <target> <url>` | `playwright-cli -s=<session> goto <url>` | Navigate |
| `$CDP snap <target>` | `playwright-cli -s=<session> snapshot` | DOM tree with refs |
| `$CDP click <target> <css>` | `playwright-cli -s=<session> click <ref>` | **ref from snapshot, NOT CSS** |
| `$CDP type <target> <text>` | `playwright-cli -s=<session> fill <ref> <text>` | Fill by ref |
| `$CDP eval <target> <js>` | `playwright-cli -s=<session> eval <js>` | Run JS |
| `$CDP shot <target>` | _(no equivalent)_ | Use `snapshot` instead |
| `$CDP html <target>` | `playwright-cli -s=<session> eval "document.documentElement.outerHTML"` | Get HTML |

**Key difference**: playwright-cli uses **element refs** from `snapshot` (e.g. `ref="e42"`), not CSS selectors. Always `snapshot` first, then use the ref.
