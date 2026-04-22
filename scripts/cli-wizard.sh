#!/usr/bin/env bash
# cli-wizard.sh
# Enhanced interactive CLI wizard for the QA Agent Platform.
# Guides users through complete setup: folder analysis, framework detection,
# credential configuration, and pipeline launching.
#
# Usage:
#   ./scripts/cli-wizard.sh [--setup | --run | --status | --dashboard]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────

# Strip terminal control characters (arrow keys, escape sequences) from input.
# Git Bash on Windows captures arrow keys as literal [D, [C, etc.
sanitize_input() {
    # Remove ANSI escape sequences, control chars, terminal artifacts, and non-printable chars
    echo "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed 's/\[[][A-D]//g' | sed 's/\[[A-D]//g' | sed 's/[\x00-\x1F\x7F-\x9F]//g' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

banner() {
    echo ""
    echo -e "${BOLD}${BLUE}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║                                                          ║"
    echo "  ║     QA Agent Platform — Interactive Setup Wizard         ║"
    echo "  ║     Autonomous E2E Test Generation                       ║"
    echo "  ║                                                          ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

section() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━ $1 ━━━${NC}"
    echo ""
}

info()    { echo -e "  ${CYAN}[i]${NC} $1"; }
success() { echo -e "  ${GREEN}[+]${NC} $1"; }
warn()    { echo -e "  ${YELLOW}[!]${NC} $1"; }
error()   { echo -e "  ${RED}[x]${NC} $1"; }
prompt()  { echo -e "  ${MAGENTA}[?]${NC} $1"; }

divider() {
    echo -e "  ${DIM}────────────────────────────────────────────${NC}"
}

# ── Prerequisites ────────────────────────────────────────────────────────────

check_prereqs() {
    section "Step 1/6: Checking Prerequisites"

    local MISSING=()
    command -v node   &>/dev/null || MISSING+=("node    → https://nodejs.org")
    command -v npx    &>/dev/null || MISSING+=("npx     → comes with Node.js")
    command -v git    &>/dev/null || MISSING+=("git     → https://git-scm.com")
    command -v python3 &>/dev/null || MISSING+=("python3 → https://python.org")
    command -v curl   &>/dev/null || MISSING+=("curl    → usually pre-installed")

    # Optional but recommended
    local OPTIONAL=()
    command -v jq     &>/dev/null || OPTIONAL+=("jq      → scoop install jq / choco install jq")
    command -v claude  &>/dev/null || OPTIONAL+=("claude  → npm install -g @anthropic-ai/claude-code")

    if [ ${#MISSING[@]} -gt 0 ]; then
        error "Missing required tools:"
        for tool in "${MISSING[@]}"; do echo -e "    ${RED}- $tool${NC}"; done
        echo ""
        echo "  Install them and re-run this wizard."
        exit 1
    fi

    success "All required tools found"

    if [ ${#OPTIONAL[@]} -gt 0 ]; then
        warn "Optional tools not found (recommended):"
        for tool in "${OPTIONAL[@]}"; do echo -e "    ${DIM}- $tool${NC}"; done
    fi

    echo ""
    success "Node $(node --version 2>/dev/null || echo 'unknown')"
    success "Git $(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 'unknown')"
    success "Python $(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 'unknown')"
}

# ── Project Folder ───────────────────────────────────────────────────────────

select_project() {
    section "Step 2/6: Project Folder"

    prompt "Enter the path to your test project folder"
    echo -e "  ${DIM}Examples:${NC}"
    echo -e "  ${DIM}  C:/Users/you/Desktop/my-tests${NC}"
    echo -e "  ${DIM}  /home/you/projects/qa-tests${NC}"
    echo -e "  ${DIM}  . (current directory)${NC}"
    echo ""
    read -rp "  Project path: " PROJECT_PATH_RAW

    # Sanitize: strip control characters (arrow keys produce [D,[C on Git Bash)
    PROJECT_PATH_RAW=$(sanitize_input "$PROJECT_PATH_RAW")
    # Remove surrounding quotes
    PROJECT_PATH_RAW=$(echo "$PROJECT_PATH_RAW" | sed 's/^"//;s/"$//')
    # Normalize backslashes to forward slashes
    PROJECT_PATH="${PROJECT_PATH_RAW//\\//}"

    if [ -z "$PROJECT_PATH" ]; then
        error "No path provided."
        exit 1
    fi

    # Expand ~ if present
    PROJECT_PATH="${PROJECT_PATH/#\~/$HOME}"

    echo ""
    if [ -d "$PROJECT_PATH" ]; then
        success "Folder exists: $PROJECT_PATH"
    else
        prompt "Folder does not exist: $PROJECT_PATH"
        read -rp "  Create it? (y/n) [y]: " CREATE_FOLDER
        CREATE_FOLDER="${CREATE_FOLDER:-y}"
        if [ "$CREATE_FOLDER" = "y" ] || [ "$CREATE_FOLDER" = "Y" ]; then
            mkdir -p "$PROJECT_PATH"
            success "Created: $PROJECT_PATH"
        else
            error "Folder does not exist. Aborting."
            exit 1
        fi
    fi
}

# ── Framework Detection ──────────────────────────────────────────────────────

detect_framework() {
    section "Step 3/6: Framework Detection"

    # The detection script outputs ONLY the framework ID to stdout.
    # All display/UI text goes to /dev/tty inside the script.
    FRAMEWORK=$("$SCRIPT_DIR/detect-framework-interactive.sh" "$PROJECT_PATH") || {
        error "Framework detection cancelled."
        exit 1
    }

    # Sanitize just in case
    FRAMEWORK=$(sanitize_input "$FRAMEWORK")

    # Map framework to language
    case "$FRAMEWORK" in
        playwright-js|cypress-js|puppeteer-js|testcafe-js|webdriverio-js) LANG="javascript" ;;
        playwright-typescript) LANG="typescript" ;;
        playwright-python|selenium-python|appium-python) LANG="python" ;;
        selenium-java|appium-java) LANG="java" ;;
        robot-framework) LANG="python" ;;
        *) LANG="javascript" ;;
    esac

    echo ""
    success "Selected framework: $FRAMEWORK ($LANG)"
}

# ── Ticket System ────────────────────────────────────────────────────────────

configure_tickets() {
    section "Step 4/6: Ticket Management System"

    prompt "Which ticket system do you use?"
    echo ""
    echo -e "    ${BOLD}1)${NC}  Jira"
    echo -e "    ${BOLD}2)${NC}  GitHub Issues"
    echo -e "    ${BOLD}3)${NC}  Azure DevOps"
    echo -e "    ${BOLD}4)${NC}  Linear"
    echo -e "    ${BOLD}5)${NC}  ServiceNow"
    echo -e "    ${BOLD}6)${NC}  None / Skip"
    echo ""
    read -rp "  Enter choice (1-6) [6]: " TICKET_CHOICE
    TICKET_CHOICE="${TICKET_CHOICE:-6}"

    case "$TICKET_CHOICE" in
        1)
            TICKET_PLATFORM="jira-any"
            echo ""
            info "Configuring Jira..."
            read -rp "  Jira Base URL (e.g., https://yourorg.atlassian.net): " JIRA_BASE_URL
            JIRA_BASE_URL=$(sanitize_input "$JIRA_BASE_URL")
            # Remove trailing slash
            JIRA_BASE_URL="${JIRA_BASE_URL%/}"

            read -rp "  Jira User Email: " JIRA_USER
            JIRA_USER=$(sanitize_input "$JIRA_USER")

            read -rsp "  Jira API Token: " JIRA_TOKEN
            echo ""
            JIRA_TOKEN=$(sanitize_input "$JIRA_TOKEN")

            if [ -n "$JIRA_BASE_URL" ] && [ -n "$JIRA_USER" ] && [ -n "$JIRA_TOKEN" ]; then
                export JIRA_BASE_URL JIRA_USER JIRA_TOKEN
                info "Validating Jira credentials..."
                local JIRA_HTTP_CODE
                JIRA_HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
                    -u "${JIRA_USER}:${JIRA_TOKEN}" \
                    -H "Accept: application/json" \
                    "${JIRA_BASE_URL}/rest/api/2/myself" 2>/dev/null) || JIRA_HTTP_CODE="000"

                if [ "$JIRA_HTTP_CODE" = "200" ]; then
                    success "Jira authentication successful (HTTP 200)"
                else
                    warn "Jira auth returned HTTP ${JIRA_HTTP_CODE}. Check token in .env later."
                    info "Token saved to .env -- you can update it there if needed."
                fi
            fi
            ;;
        2)
            TICKET_PLATFORM="github-issues"
            echo ""
            read -rsp "  GitHub Token (ghp_...): " GH_TOKEN
            echo ""
            GH_TOKEN=$(sanitize_input "$GH_TOKEN")

            read -rp "  GitHub Repo (org/repo or full URL): " GH_REPO
            GH_REPO=$(sanitize_input "$GH_REPO")
            # Extract org/repo from full URL if given
            # e.g., https://github.com/Tanyagarg12/AI-Agnet.git -> Tanyagarg12/AI-Agnet
            if echo "$GH_REPO" | grep -q "github.com"; then
                GH_REPO=$(echo "$GH_REPO" | sed 's|.*github\.com[:/]\([^/]*/[^/.]*\).*|\1|')
            fi
            # Remove .git suffix
            GH_REPO="${GH_REPO%.git}"

            export GH_REPO GH_TOKEN
            info "Repo set to: $GH_REPO"
            ;;
        3)
            TICKET_PLATFORM="azure-devops"
            echo ""
            read -rp "  Azure DevOps Org URL (e.g., https://dev.azure.com/yourorg): " ADO_ORG
            read -rp "  Project Name: " ADO_PROJECT
            read -rsp "  Personal Access Token: " ADO_PAT
            echo ""
            export ADO_ORG ADO_PROJECT ADO_PAT
            ;;
        4)
            TICKET_PLATFORM="linear"
            echo ""
            read -rsp "  Linear API Key: " LINEAR_API_KEY
            echo ""
            read -rp "  Team ID: " LINEAR_TEAM_ID
            export LINEAR_API_KEY LINEAR_TEAM_ID
            ;;
        5)
            TICKET_PLATFORM="servicenow"
            echo ""
            read -rp "  ServiceNow Instance: " SNOW_INSTANCE
            read -rp "  Username: " SNOW_USER
            read -rsp "  Password: " SNOW_PASSWORD
            echo ""
            export SNOW_INSTANCE SNOW_USER SNOW_PASSWORD
            ;;
        6)
            TICKET_PLATFORM="none"
            info "Skipping ticket system configuration."
            ;;
        *)
            TICKET_PLATFORM="none"
            ;;
    esac
}

# ── Git Provider ─────────────────────────────────────────────────────────────

configure_git() {
    section "Step 5/6: Git Provider"

    prompt "Which Git provider do you use?"
    echo ""
    echo -e "    ${BOLD}1)${NC}  GitHub"
    echo -e "    ${BOLD}2)${NC}  GitLab"
    echo -e "    ${BOLD}3)${NC}  Bitbucket / Azure Repos"
    echo -e "    ${BOLD}4)${NC}  None / Skip"
    echo ""
    read -rp "  Enter choice (1-4) [4]: " GIT_CHOICE
    GIT_CHOICE="${GIT_CHOICE:-4}"

    case "$GIT_CHOICE" in
        1)
            VCS_PROVIDER="github"
            if [ -z "${GH_TOKEN:-}" ]; then
                read -rsp "  GitHub Personal Access Token (ghp_...): " GH_TOKEN
                echo ""
                GH_TOKEN=$(sanitize_input "$GH_TOKEN")
                export GH_TOKEN
            else
                info "Using GitHub token from ticket step"
            fi
            if [ -z "${GH_REPO:-}" ]; then
                read -rp "  GitHub Repo (org/repo or full URL): " GH_REPO
                GH_REPO=$(sanitize_input "$GH_REPO")
                # Extract org/repo from full URL
                if echo "$GH_REPO" | grep -q "github.com"; then
                    GH_REPO=$(echo "$GH_REPO" | sed 's|.*github\.com[:/]\([^/]*/[^/.]*\).*|\1|')
                fi
                GH_REPO="${GH_REPO%.git}"
                export GH_REPO
                info "Repo set to: $GH_REPO"
            else
                info "Using GitHub repo from ticket step: $GH_REPO"
            fi

            if [ -n "${GH_TOKEN:-}" ]; then
                info "Validating GitHub credentials..."
                local GH_HTTP_CODE
                GH_HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
                    -H "Authorization: Bearer ${GH_TOKEN}" \
                    -H "Accept: application/vnd.github+json" \
                    "https://api.github.com/user" 2>/dev/null) || GH_HTTP_CODE="000"

                if [ "$GH_HTTP_CODE" = "200" ]; then
                    success "GitHub authentication successful (HTTP 200)"
                else
                    warn "GitHub auth returned HTTP ${GH_HTTP_CODE}. Check GH_TOKEN in .env."
                fi
            fi
            ;;
        2)
            VCS_PROVIDER="gitlab"
            read -rsp "  GitLab Personal Access Token: " GITLAB_TOKEN
            echo ""
            export GITLAB_TOKEN
            read -rp "  GitLab API URL [https://gitlab.com/api/v4]: " GITLAB_API_URL
            GITLAB_API_URL="${GITLAB_API_URL:-https://gitlab.com/api/v4}"
            export GITLAB_API_URL
            ;;
        3)
            VCS_PROVIDER="azure-repos"
            if [ -z "${ADO_PAT:-}" ]; then
                read -rsp "  Azure DevOps PAT: " ADO_PAT
                echo ""
                export ADO_PAT
            fi
            ;;
        4)
            VCS_PROVIDER="none"
            info "Skipping Git provider configuration."
            ;;
        *)
            VCS_PROVIDER="none"
            ;;
    esac
}

# ── Environment / App URL ───────────────────────────────────────────────────

configure_environment() {
    section "Step 6/6: Test Environment"

    prompt "Enter your application URL for testing"
    echo -e "  ${DIM}This is the URL the agent will navigate to during test generation${NC}"
    echo ""
    read -rp "  App URL (e.g., https://staging.yourapp.com): " APP_URL
    APP_URL="${APP_URL:-https://staging.yourapp.com}"

    echo ""
    read -rp "  Test user email: " TEST_USER
    TEST_USER="${TEST_USER:-automation@yourapp.com}"

    read -rsp "  Test user password: " TEST_PASSWORD
    echo ""
    TEST_PASSWORD="${TEST_PASSWORD:-}"

    echo ""
    read -rp "  Target branch for PRs [main]: " PR_TARGET
    PR_TARGET="${PR_TARGET:-main}"
}

# ── Write .env ───────────────────────────────────────────────────────────────

write_env() {
    section "Writing Configuration"

    # Write clean .env -- NO preserved vars (old .env was corrupted)
    cat > "$ENV_FILE" <<ENVEOF
# QA Agent Platform -- Environment Configuration
# Generated by cli-wizard.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Re-run: ./scripts/cli-wizard.sh --setup

# -- Test Project --
GP_TEST_PROJECT_PATH=${PROJECT_PATH}
GP_FRAMEWORK=${FRAMEWORK}
GP_LANGUAGE=${LANG}
GP_PR_TARGET_BRANCH=${PR_TARGET:-main}
GP_TICKET_PLATFORM=${TICKET_PLATFORM:-none}
GP_VCS_PROVIDER=${VCS_PROVIDER:-none}

# -- Test Environment --
STAGING_URL=${APP_URL:-https://staging.yourapp.com}
STAGING_USER=${TEST_USER:-automation@yourapp.com}
STAGING_PASSWORD=${TEST_PASSWORD:-}
TEST_ENV=staging
HEADLESS=true
TEST_TIMEOUT=30000

# -- Jira --
JIRA_BASE_URL=${JIRA_BASE_URL:-}
JIRA_USER=${JIRA_USER:-}
JIRA_TOKEN=${JIRA_TOKEN:-}

# -- GitHub --
GH_TOKEN=${GH_TOKEN:-}
GH_REPO=${GH_REPO:-}

# -- GitLab --
GITLAB_TOKEN=${GITLAB_TOKEN:-}
GITLAB_API_URL=${GITLAB_API_URL:-https://gitlab.com/api/v4}

# -- Azure DevOps --
ADO_ORG=${ADO_ORG:-}
ADO_PROJECT=${ADO_PROJECT:-}
ADO_PAT=${ADO_PAT:-}

# -- Linear --
LINEAR_API_KEY=${LINEAR_API_KEY:-}
LINEAR_TEAM_ID=${LINEAR_TEAM_ID:-}

# -- ServiceNow --
SNOW_INSTANCE=${SNOW_INSTANCE:-}
SNOW_USER=${SNOW_USER:-}
SNOW_PASSWORD=${SNOW_PASSWORD:-}

# -- Dashboard --
DASHBOARD_URL=http://localhost:3459
DASHBOARD_PORT=3459
ENVEOF

    success "Configuration written to .env"
}

# ── Scaffold Project ─────────────────────────────────────────────────────────

scaffold_project() {
    section "Scaffolding Project"

    # Check if project already has code
    local HAS_CODE=false
    [ -f "$PROJECT_PATH/package.json" ]      && HAS_CODE=true
    [ -f "$PROJECT_PATH/pom.xml" ]           && HAS_CODE=true
    [ -f "$PROJECT_PATH/requirements.txt" ]  && HAS_CODE=true
    [ -f "$PROJECT_PATH/Pipfile" ]           && HAS_CODE=true
    [ -f "$PROJECT_PATH/pyproject.toml" ]    && HAS_CODE=true

    if [ "$HAS_CODE" = true ]; then
        info "Existing project detected — checking dependencies only"
    else
        info "Creating project structure for $FRAMEWORK..."
        # Delegate to existing setup.sh scaffolding logic by running it non-interactively
        "$SCRIPT_DIR/gp-install-framework.sh" "$FRAMEWORK" "$PROJECT_PATH" 2>/dev/null || {
            warn "Auto-scaffold failed. You may need to set up the project manually."
        }
    fi

    success "Project ready at: $PROJECT_PATH"
}

# ── Final Summary ────────────────────────────────────────────────────────────

show_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║                   Setup Complete!                        ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "  ${BOLD}Configuration:${NC}"
    echo -e "    Framework:    ${GREEN}$FRAMEWORK${NC} ($LANG)"
    echo -e "    Project:      ${CYAN}$PROJECT_PATH${NC}"
    echo -e "    Tickets:      ${TICKET_PLATFORM:-none}"
    echo -e "    VCS:          ${VCS_PROVIDER:-none}"
    echo -e "    App URL:      ${APP_URL:-not set}"
    echo -e "    PR Target:    ${PR_TARGET:-main}"
    echo ""
    divider
    echo ""
    echo -e "  ${BOLD}Quick Start Commands:${NC}"
    echo ""
    echo -e "    ${DIM}# Start the dashboard${NC}"
    echo -e "    ${BOLD}./scripts/cli-wizard.sh --dashboard${NC}"
    echo ""
    echo -e "    ${DIM}# Run a pipeline from a ticket${NC}"
    echo -e "    ${BOLD}claude${NC}"
    echo -e "    ${BOLD}/gp-test-agent PROJ-123 --auto${NC}"
    echo ""
    echo -e "    ${DIM}# Run CLI mode (interactive)${NC}"
    echo -e "    ${BOLD}./scripts/cli-wizard.sh --run${NC}"
    echo ""
    echo -e "    ${DIM}# Check system status${NC}"
    echo -e "    ${BOLD}./scripts/cli-wizard.sh --status${NC}"
    echo ""
    divider
    echo ""
}

# ── Run Mode ─────────────────────────────────────────────────────────────────

run_mode() {
    banner

    # Load env
    if [ -f "$ENV_FILE" ]; then
        set -a; source "$ENV_FILE" 2>/dev/null || true; set +a
    else
        error "No .env found. Run: ./scripts/cli-wizard.sh --setup"
        exit 1
    fi

    section "Pipeline Launcher"

    prompt "What would you like to do?"
    echo ""
    echo -e "    ${BOLD}1)${NC}  Generate E2E test from ticket"
    echo -e "    ${BOLD}2)${NC}  Discover testable changes (scan repos)"
    echo -e "    ${BOLD}3)${NC}  Fix failing tests"
    echo -e "    ${BOLD}4)${NC}  Initialize new test project"
    echo -e "    ${BOLD}5)${NC}  Check pipeline status"
    echo -e "    ${BOLD}6)${NC}  Open dashboard"
    echo ""
    read -rp "  Choice (1-6): " ACTION

    case "$ACTION" in
        1)
            read -rp "  Ticket key or URL: " TICKET
            read -rp "  Auto mode? (y/n) [y]: " AUTO_MODE
            AUTO_MODE="${AUTO_MODE:-y}"

            local CMD="/gp-test-agent $TICKET --framework ${GP_FRAMEWORK:-playwright-js}"
            [ "$AUTO_MODE" = "y" ] && CMD="$CMD --auto"

            echo ""
            info "Launching: $CMD"
            echo ""
            claude -p "$CMD"
            ;;
        2)
            echo ""
            info "Launching discovery pipeline..."
            claude -p "/qa-discover-changes"
            ;;
        3)
            echo ""
            info "Launching fix pipeline..."
            claude -p "/gp-fix-tests"
            ;;
        4)
            info "Launching project init..."
            claude -p "/gp-init-project --framework ${GP_FRAMEWORK:-playwright-js}"
            ;;
        5)
            status_mode
            ;;
        6)
            dashboard_mode
            ;;
        *)
            error "Invalid choice"
            exit 1
            ;;
    esac
}

# ── Status Mode ──────────────────────────────────────────────────────────────

status_mode() {
    section "System Status"

    local DASHBOARD="${DASHBOARD_URL:-http://localhost:3459}"

    # Try to reach dashboard
    if curl -sf "${DASHBOARD}/api/status" > /dev/null 2>&1; then
        local STATUS
        STATUS=$(curl -sf "${DASHBOARD}/api/status")
        echo "$STATUS" | python3 -c "
import sys, json
s = json.load(sys.stdin)
p = s.get('pipelines', {})
w = s.get('workers', {})
print(f'  Dashboard:    Online')
print(f'  Uptime:       {int(s.get(\"uptime\", 0))}s')
print(f'  Pipelines:    {p.get(\"total\", 0)} total, {p.get(\"running\", 0)} running, {p.get(\"completed\", 0)} done, {p.get(\"failed\", 0)} failed')
print(f'  Workers:      {w.get(\"total\", 0)} connected, {w.get(\"available\", 0)} available')
print(f'  WS Clients:   {s.get(\"wsClients\", 0)}')
" 2>/dev/null || echo "  Could not parse status response."
    else
        warn "Dashboard not reachable at $DASHBOARD"
        echo "  Start it with: ./scripts/cli-wizard.sh --dashboard"
    fi
}

# ── Dashboard Mode ───────────────────────────────────────────────────────────

dashboard_mode() {
    section "Starting Dashboard"

    # Install dependencies if needed
    if [ ! -d "$PROJECT_DIR/dashboard/node_modules" ]; then
        info "Installing dashboard dependencies..."
        (cd "$PROJECT_DIR/dashboard" && npm install --quiet)
    fi

    local PORT="${DASHBOARD_PORT:-3459}"
    info "Starting dashboard on http://localhost:${PORT}"
    echo ""
    echo -e "  ${DIM}Press Ctrl+C to stop${NC}"
    echo ""

    (cd "$PROJECT_DIR/dashboard" && node server.js)
}

# ── Main ─────────────────────────────────────────────────────────────────────

CMD="${1:---setup}"

case "$CMD" in
    --setup|-s)
        banner
        check_prereqs
        select_project
        detect_framework
        configure_tickets
        configure_git
        configure_environment
        write_env
        scaffold_project
        show_summary
        ;;
    --run|-r)
        run_mode
        ;;
    --status)
        status_mode
        ;;
    --dashboard|-d)
        dashboard_mode
        ;;
    --help|-h)
        echo "QA Agent Platform — CLI Wizard"
        echo ""
        echo "Usage: ./scripts/cli-wizard.sh [command]"
        echo ""
        echo "Commands:"
        echo "  --setup, -s       Full interactive setup (default)"
        echo "  --run, -r         Launch a pipeline interactively"
        echo "  --status          Check system status"
        echo "  --dashboard, -d   Start the dashboard web UI"
        echo "  --help, -h        Show this help"
        ;;
    *)
        error "Unknown command: $CMD"
        echo "  Run: ./scripts/cli-wizard.sh --help"
        exit 1
        ;;
esac
