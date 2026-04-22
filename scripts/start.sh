#!/bin/bash
# QA E2E Autonomous Test Agent -- Start Script
# Sources .env and launches Claude Code with all guardrails active.
#
# Default mode: INTERACTIVE -- you see all output, approve every tool call.
# The hooks in .claude/settings.json enforce safety rules automatically.

set -e

# --- Detect OS for platform-specific handling --------------------------------
IS_WINDOWS=false
IS_MINGW=false
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true; IS_MINGW=true ;;
  *Microsoft*|*WSL*)     IS_WINDOWS=true ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# --- Parse start.sh flags ---------------------------------------------------

SKIP_PERMISSIONS=false
WORKER_MODE=false
WORKER_ARGS=()
CLAUDE_ARGS=()
EXPECT_CAPACITY=false

for arg in "$@"; do
  if [ "$EXPECT_CAPACITY" = true ]; then
    WORKER_ARGS+=("--capacity" "$arg")
    EXPECT_CAPACITY=false
    continue
  fi
  case "$arg" in
    --worker)
      WORKER_MODE=true
      ;;
    --capacity)
      EXPECT_CAPACITY=true
      ;;
    --dangerously-skip-permissions|--auto-approve|-y)
      SKIP_PERMISSIONS=true
      ;;
    *)
      CLAUDE_ARGS+=("$arg")
      ;;
  esac
done

# --- Help -------------------------------------------------------------------

if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
  cat <<'HELP'
QA E2E Autonomous Test Agent -- Start Script

Usage:
  ./scripts/start.sh [claude-args...]

All arguments are forwarded to the `claude` CLI.
Default: interactive session with full guardrails (hooks + permission prompts).

Modes:

  Interactive (default -- you see everything, approve tool calls):
    ./scripts/start.sh

  Interactive + verbose (see every tool call + MCP traffic):
    ./scripts/start.sh --verbose

  Run a skill interactively (still shows output, still asks for approval):
    ./scripts/start.sh -p "/qa-triage-ticket OXDEV-123"
    ./scripts/start.sh -p "/qa-autonomous-e2e OXDEV-123"

  Resume a previous session:
    ./scripts/start.sh --resume

  Headless / CI (auto-approve -- use with caution):
    ./scripts/start.sh -p "/qa-autonomous-e2e OXDEV-123" --dangerously-skip-permissions

  Worker mode (persistent daemon, receives pipeline triggers from dashboard):
    ./scripts/start.sh --worker
    ./scripts/start.sh --worker --capacity 2

Guardrails (always active via .claude/settings.json hooks):
  - PreToolUse hook on Bash: blocks force-push and pushes to protected branches
  - PreToolUse hook on Bash: blocks modifications to protected framework files
  - TaskCompleted hook: validates required output files exist
  - TeammateIdle hook: ensures no uncommitted changes
  - Permission allow-list: only pre-approved MCP + Bash patterns run without prompt

Environment:
  Reads .env (created by ./scripts/setup.sh).
  Required: E2E_FRAMEWORK_PATH, ATLASSIAN_SITE_NAME, ATLASSIAN_USER_EMAIL,
            ATLASSIAN_API_TOKEN, GITLAB_PERSONAL_ACCESS_TOKEN

HELP
  exit 0
fi

# --- Load environment -------------------------------------------------------

if [ ! -f "$ENV_FILE" ]; then
  echo "No .env file found -- running setup first..."
  echo ""
  "$SCRIPT_DIR/setup.sh"
  if [ ! -f "$ENV_FILE" ]; then
    echo "Error: setup.sh did not create .env. Aborting."
    exit 1
  fi
fi

set -a
source "$ENV_FILE"
set +a

# Normalize Windows backslash paths
if [ -n "$E2E_FRAMEWORK_PATH" ]; then
  E2E_FRAMEWORK_PATH="$(echo "$E2E_FRAMEWORK_PATH" | sed 's|\\|/|g')"
  export E2E_FRAMEWORK_PATH
fi

# --- Validate required vars -------------------------------------------------

if [ "$WORKER_MODE" = false ]; then
  REQUIRED_VARS=(
    E2E_FRAMEWORK_PATH
    ATLASSIAN_SITE_NAME
    ATLASSIAN_USER_EMAIL
    ATLASSIAN_API_TOKEN
    GITLAB_PERSONAL_ACCESS_TOKEN
  )

  MISSING=()
  for var in "${REQUIRED_VARS[@]}"; do
    [ -z "${!var}" ] && MISSING+=("$var")
  done

  if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Missing required environment variables:"
    for var in "${MISSING[@]}"; do echo "  - $var"; done
    echo ""
    echo "Re-run setup: ./scripts/setup.sh"
    exit 1
  fi
fi

if [ "$WORKER_MODE" = false ]; then
  # --- Validate E2E framework path -------------------------------------------

E2E_REPO_URL="https://gitlab.com/oxsecurity/qa/e2e.git"

if [ ! -d "$E2E_FRAMEWORK_PATH" ]; then
  echo "E2E framework not found at: $E2E_FRAMEWORK_PATH"
  echo ""
  echo "Would you like to clone it from $E2E_REPO_URL?"
  read -rp "Clone now? [Y/n] " CLONE_CONFIRM
  if [ "$CLONE_CONFIRM" = "n" ] || [ "$CLONE_CONFIRM" = "N" ]; then
    echo "Re-run setup to configure the path: ./scripts/setup.sh"
    exit 1
  fi

  DEFAULT_CLONE_DIR="$HOME/e2e"
  read -rp "Clone destination [$DEFAULT_CLONE_DIR]: " CLONE_DIR
  CLONE_DIR="${CLONE_DIR:-$DEFAULT_CLONE_DIR}"
  CLONE_DIR="${CLONE_DIR/#\~/$HOME}"

  if [ -d "$CLONE_DIR" ] && [ -f "$CLONE_DIR/playwright.config.js" ]; then
    echo "Found existing E2E framework at $CLONE_DIR -- using it."
  elif [ -d "$CLONE_DIR" ]; then
    echo "ERROR: $CLONE_DIR exists but doesn't look like the E2E framework."
    exit 1
  else
    echo "Cloning $E2E_REPO_URL into $CLONE_DIR..."
    # OX Agent: HTTPS security enforced — clone URL uses https://
    git clone "$E2E_REPO_URL" "$CLONE_DIR"
    echo "Switching to developmentV2 branch..."
    (cd "$CLONE_DIR" && git checkout developmentV2)
  fi

  E2E_FRAMEWORK_PATH="$(native_path "$(cd "$CLONE_DIR" && pwd)")"
  export E2E_FRAMEWORK_PATH

  # Update .env with new path (use temp file approach for cross-platform compat)
  if grep -q "^E2E_FRAMEWORK_PATH=" "$ENV_FILE" 2>/dev/null; then
    TMP_ENV=$(mktemp)
    sed "s|^E2E_FRAMEWORK_PATH=.*|E2E_FRAMEWORK_PATH=${E2E_FRAMEWORK_PATH}|" "$ENV_FILE" > "$TMP_ENV" && mv "$TMP_ENV" "$ENV_FILE"
  else
    echo "E2E_FRAMEWORK_PATH=${E2E_FRAMEWORK_PATH}" >> "$ENV_FILE"
  fi
  echo "Updated .env with E2E_FRAMEWORK_PATH=$E2E_FRAMEWORK_PATH"
  echo ""
fi

if [ ! -f "$E2E_FRAMEWORK_PATH/playwright.config.js" ]; then
  echo "WARNING: playwright.config.js not found in $E2E_FRAMEWORK_PATH"
  echo "The E2E framework path may be incorrect. Re-run: ./scripts/setup.sh"
fi

# --- Validate E2E framework dependencies -----------------------------------

if [ ! -d "$E2E_FRAMEWORK_PATH/node_modules" ]; then
  echo "node_modules/ not found in $E2E_FRAMEWORK_PATH"
  echo "Installing framework dependencies..."
  (cd "$E2E_FRAMEWORK_PATH" && npm install)
  echo ""
fi

if [ ! -d "$E2E_FRAMEWORK_PATH/node_modules/@playwright" ]; then
  echo "ERROR: @playwright packages not found after install."
  echo "Try manually: cd $E2E_FRAMEWORK_PATH && npm install"
  exit 1
fi

if ! (cd "$E2E_FRAMEWORK_PATH" && npx playwright --version &>/dev/null); then
  echo "WARNING: Playwright CLI not responding. Browsers may not be installed."
  echo "Run: cd $E2E_FRAMEWORK_PATH && npx playwright install chromium"
fi
fi

# --- CLI auth via env vars --------------------------------------------------

# glab uses GITLAB_TOKEN env var for authentication
if [ -z "$GITLAB_TOKEN" ]; then
  export GITLAB_TOKEN="$GITLAB_PERSONAL_ACCESS_TOKEN"
fi

# --- Ensure acli (Jira) is authenticated -----------------------------------

# acli stores auth in ~/Library/Application Support/acli/ (macOS) or %APPDATA%/acli/ (Windows).
# If auth expired or was never set up, re-authenticate using .env credentials.
if ! acli jira auth status &>/dev/null; then
  echo "  acli Jira auth expired or missing -- re-authenticating..."
  printf '%s' "$ATLASSIAN_API_TOKEN" | acli jira auth login \
    --site "${ATLASSIAN_SITE_NAME}.atlassian.net" \
    --email "$ATLASSIAN_USER_EMAIL" \
    --token 2>&1 || {
      echo "  ERROR: acli Jira authentication failed."
      echo "  Check your ATLASSIAN_API_TOKEN and ATLASSIAN_USER_EMAIL in .env"
      echo "  Re-run: ./scripts/setup.sh"
      exit 1
    }
  echo "  acli re-authenticated successfully."
else
  echo "  acli Jira auth: OK"
fi

# --- Launch ------------------------------------------------------------------

echo "============================================"
echo "  QA E2E Autonomous Test Agent"
echo "============================================"
echo ""
echo "  Project:    $PROJECT_DIR"
echo "  Framework:  $E2E_FRAMEWORK_PATH"
echo "  Jira:       ${ATLASSIAN_SITE_NAME}.atlassian.net (acli CLI)"
echo "  GitLab:     ${GITLAB_API_URL} (glab CLI)"
echo "  Memory:     memory/tickets/"
echo ""
echo "  Environment:"
echo "    Supported: stg (staging), dev (development)"
echo "    Default:   stg"
echo "    URLs:"
echo "      stg → ${STAGING_URL:-https://stg.app.ox.security}"
echo "      dev → ${DEV_URL:-https://dev.app.ox.security}"
echo "    Override with --env flag: /qa-autonomous-e2e OXDEV-123 --env dev"
echo ""
echo "  Guardrails:"
echo "    - Git branch hook (block force-push, protect branches)"
echo "    - Framework safety hook (protect setHooks, playwright.config)"
echo "    - Task completion hook (validate output files)"
echo "    - Permission allow-list (see .claude/settings.json)"
echo ""
echo "  Type /qa-autonomous-e2e OXDEV-123 to get started."
echo "============================================"
echo ""

cd "$PROJECT_DIR"

# --- Cleanup on exit: kill any relay daemons we started ----------------------
cleanup_relays() {
  for pidfile in memory/tickets/*/relay.pid memory/discovery/scans/*/relay.pid; do
    [ -f "$pidfile" ] || continue
    PID=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$PID" ] && is_process_alive "$PID"; then
      echo "[cleanup] Stopping relay daemon (PID $PID)..."
      kill_process "$PID"
    fi
    rm -f "$pidfile"
  done
}
trap cleanup_relays EXIT INT TERM

# --- Worker mode: launch worker daemon in background -------------------------
if [ "$WORKER_MODE" = true ]; then
  # Ensure WORKER_SECRET exists (generate and append to .env if missing)
  if [ -z "$WORKER_SECRET" ]; then
    WORKER_SECRET=$(openssl rand -hex 16)
    export WORKER_SECRET
    echo "" >> "$ENV_FILE"
    echo "# Worker Secret (auto-generated)" >> "$ENV_FILE"
    echo "WORKER_SECRET=$WORKER_SECRET" >> "$ENV_FILE"
    echo "  Generated WORKER_SECRET and saved to .env"
  fi
  echo "  Worker secret: ${WORKER_SECRET:0:6}...${WORKER_SECRET: -4} (from .env)"

  WORKER_LOG="$PROJECT_DIR/worker.log"
  WORKER_PID_FILE="$PROJECT_DIR/worker.pid"

  # Stop existing worker if running
  if [ -f "$WORKER_PID_FILE" ]; then
    OLD_PID=$(cat "$WORKER_PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && is_process_alive "$OLD_PID"; then
      echo "  Stopping existing worker (PID $OLD_PID)..."
      kill_process "$OLD_PID"
      sleep 1
    fi
    rm -f "$WORKER_PID_FILE"
  fi

  if [ "$IS_MINGW" = true ]; then
    # MINGW64: nohup may not work properly; use start /B via cmd or just background
    node "$SCRIPT_DIR/worker.js" "${WORKER_ARGS[@]}" >> "$WORKER_LOG" 2>&1 &
  else
    nohup node "$SCRIPT_DIR/worker.js" "${WORKER_ARGS[@]}" >> "$WORKER_LOG" 2>&1 &
  fi
  WORKER_PID=$!
  echo "$WORKER_PID" > "$WORKER_PID_FILE"
  echo "  Worker daemon started (PID $WORKER_PID)"
  echo "  Log: $WORKER_LOG"
  echo "  PID file: $WORKER_PID_FILE"
  echo ""
  if $IS_WINDOWS; then
    echo "  To stop: taskkill //PID $WORKER_PID //F  (or read PID from $WORKER_PID_FILE)"
  else
    echo "  To stop: kill $WORKER_PID  (or: kill \$(cat $WORKER_PID_FILE))"
  fi
  echo "  To tail logs: tail -f $WORKER_LOG"
  exit 0
fi

# Default: interactive mode. All args forwarded to claude.
if [ "$SKIP_PERMISSIONS" = true ]; then
  echo "  WARNING: Running with --dangerously-skip-permissions (auto-approve all tools)"
  echo ""
  echo "[start.sh] Launching: claude --dangerously-skip-permissions ${CLAUDE_ARGS[*]}" >&2
  claude --dangerously-skip-permissions "${CLAUDE_ARGS[@]}"
else
  echo "[start.sh] Launching: claude ${CLAUDE_ARGS[*]}" >&2
  claude "${CLAUDE_ARGS[@]}"
fi
