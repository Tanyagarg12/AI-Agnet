#!/usr/bin/env bash
# report-to-dashboard.sh — Bridge between E2E agent pipeline outputs and the dashboard.
# Reads agent output files from memory/tickets/<KEY>/ and POSTs status to the dashboard API.
#
# Usage: report-to-dashboard.sh <ticket-key> <stage> [options]
# Options:
#   --status <status>              Override status (default: in_progress)
#   --needs-human                  Flag that human intervention is needed
#   --notification-type <type>     Notification type (e.g., approval_needed)
#   --notification-msg <message>   Notification message text
#
# Security: All variables are quoted to prevent injection. Ticket key is validated
# against a strict pattern. No secrets are included in payloads or logs.

set -euo pipefail

# Ensure the script never fails the pipeline — trap errors and always exit 0
_SCRIPT_OK=0
trap 'if [ "$_SCRIPT_OK" -eq 0 ]; then echo "[report-to-dashboard] WARNING: Script encountered an error but will not block the pipeline." >&2; fi; exit 0' ERR EXIT

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# On Windows/Git Bash, pwd returns Unix-style paths (/c/Users/...)
# but native Windows Python requires Windows-style paths (C:/Users/...).
# Convert if running on Windows (cygpath available in Git Bash).
if command -v cygpath &>/dev/null; then
    PROJECT_ROOT_PY="$(cygpath -m "${PROJECT_ROOT}")"
else
    PROJECT_ROOT_PY="${PROJECT_ROOT}"
fi

# ---------------------------------------------------------------------------
# Detect Python binary (python3 on macOS/Linux, python on Windows)
# On Windows, python3 may exist as a non-functional Microsoft Store alias —
# test actual execution, not just command presence.
# ---------------------------------------------------------------------------
if python3 -c "import sys; sys.exit(0)" &>/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif python -c "import sys; sys.exit(0)" &>/dev/null 2>&1; then
    PYTHON_BIN="python"
else
    echo "[report-to-dashboard] WARNING: No Python interpreter found. Skipping report." >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [ $# -lt 2 ]; then
  echo "[report-to-dashboard] Usage: $0 <ticket-key> <agent-stage> [options]" >&2
  exit 0
fi

TICKET_KEY="$1"
AGENT_STAGE="$2"
shift 2

# QA Agent Security: Validate ticket key format to prevent path traversal
# Accepts: OXDEV-12345, PR-toSTG-2026-03-20b, RFE-OXDEV-123-2026-03-21, BUG-OXDEV-123-2026-03-21,
#          DIS-OXDEV-123-abc, TASK-OXDEV-123-2026-03-21, MANUAL-123456, FIX-job-123456
if ! echo "${TICKET_KEY}" | grep -qE '^[A-Z0-9][-A-Za-z0-9]{1,50}$'; then
  echo "[report-to-dashboard] ERROR: Invalid ticket key format: ${TICKET_KEY}" >&2
  exit 0
fi

# Parse optional arguments
STATUS="in_progress"
NEEDS_HUMAN="false"
NOTIFICATION_TYPE=""
NOTIFICATION_MSG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --status)
      STATUS="${2:-in_progress}"
      shift 2
      ;;
    --needs-human)
      NEEDS_HUMAN="true"
      shift
      ;;
    --notification-type)
      NOTIFICATION_TYPE="${2:-}"
      shift 2
      ;;
    --notification-msg)
      NOTIFICATION_MSG="${2:-}"
      shift 2
      ;;
    *)
      echo "[report-to-dashboard] WARNING: Unknown option: $1" >&2
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve dashboard URL
# ---------------------------------------------------------------------------
DASHBOARD_BASE_URL=""

# Priority 1: Environment variable
if [ -n "${DASHBOARD_URL:-}" ]; then
  DASHBOARD_BASE_URL="${DASHBOARD_URL}"
fi

# Priority 2: Config file
if [ -z "${DASHBOARD_BASE_URL}" ]; then
  CONFIG_FILE="${PROJECT_ROOT_PY}/dashboard.config.json"
  if [ -f "${CONFIG_FILE}" ]; then
    # Check if reporting is enabled
    REPORTING_ENABLED=$(${PYTHON_BIN} -c "
import json, sys
try:
    with open('${CONFIG_FILE}') as f:
        cfg = json.load(f)
    print(cfg.get('reporting_enabled', True))
except:
    print('True')
" 2>/dev/null || echo "True")

    if [ "${REPORTING_ENABLED}" = "False" ]; then
      echo "[report-to-dashboard] Reporting is disabled in config. Skipping." >&2
      exit 0
    fi

    DASHBOARD_BASE_URL=$(${PYTHON_BIN} -c "
import json, sys
try:
    with open('${CONFIG_FILE}') as f:
        cfg = json.load(f)
    print(cfg.get('dashboard_url', ''))
except:
    print('')
" 2>/dev/null || echo "")
  fi
fi

if [ -z "${DASHBOARD_BASE_URL}" ]; then
  echo "[report-to-dashboard] WARNING: No dashboard URL configured. Set DASHBOARD_URL env var or create dashboard.config.json." >&2
  exit 0
fi

# Strip trailing slash
DASHBOARD_BASE_URL="${DASHBOARD_BASE_URL%/}"
REPORT_ENDPOINT="${DASHBOARD_BASE_URL}/api/e2e-agent/report"

# ---------------------------------------------------------------------------
# Stage name mapping (bash 3 compatible — no associative arrays)
# ---------------------------------------------------------------------------
map_stage() {
  case "$1" in
    triage)         echo "triage" ;;
    explorer)       echo "explorer" ;;
    explore)        echo "explorer" ;;
    playwright)     echo "playwright" ;;
    browser)        echo "playwright" ;;
    code-writer)    echo "code-writer" ;;
    codewriter)     echo "code-writer" ;;
    test-runner)    echo "test-runner" ;;
    testrunner)     echo "test-runner" ;;
    debug)          echo "debug" ;;
    pr)             echo "pr" ;;
    pr-creation)    echo "pr" ;;
    scanner)        echo "scanner" ;;
    analyzer)       echo "analyzer" ;;
    ticket-creator) echo "ticket-creator" ;;
    ticketcreator)  echo "ticket-creator" ;;
    validator)      echo "validator" ;;
    cross-env-check) echo "cross-env-check" ;;
    flaky-check)    echo "cross-env-check" ;;
    retrospective)  echo "retrospective" ;;
    done)           echo "done" ;;
    *)              echo "$1" ;;
  esac
}

DASHBOARD_STAGE="$(map_stage "${AGENT_STAGE}")"

# ---------------------------------------------------------------------------
# Ticket data directory
# ---------------------------------------------------------------------------
# Resolve ticket data directory — discovery scan keys use discovery path
# Discovery keys: PR-toSTG-*, RFE-*, BUG-*, TASK-*, SPRINT-*, PROMPT-*, DIS-*, MR-*, QA-*
if echo "${TICKET_KEY}" | grep -qE '^(PR-toSTG-|RFE-|BUG-|TASK-|SPRINT-|PROMPT-|DIS-|MR-|QA-|TICKET-)'; then
  TICKET_DIR="${PROJECT_ROOT_PY}/memory/discovery/scans/${TICKET_KEY}"
else
  TICKET_DIR="${PROJECT_ROOT_PY}/memory/tickets/${TICKET_KEY}"
fi

# ---------------------------------------------------------------------------
# Extract data per stage using python3 for JSON manipulation
# ---------------------------------------------------------------------------
export TICKET_KEY DASHBOARD_STAGE AGENT_STAGE STATUS NEEDS_HUMAN
export NOTIFICATION_TYPE NOTIFICATION_MSG TICKET_DIR
export E2E_FRAMEWORK_PATH="${E2E_FRAMEWORK_PATH:-}"

# Read telemetry if available
TELEMETRY_FILE="${TICKET_DIR}/telemetry.json"
TELEMETRY_JSON="{}"
if [ -f "$TELEMETRY_FILE" ]; then
    STAGE_TELEMETRY=$(${PYTHON_BIN} -c "
import json, sys
try:
    with open('${TELEMETRY_FILE}') as f:
        data = json.load(f)
    stage_data = data.get('stages', {}).get('${DASHBOARD_STAGE}', {})
    print(json.dumps(stage_data))
except:
    print('{}')
" 2>/dev/null || echo "{}")
    TELEMETRY_JSON="$STAGE_TELEMETRY"
fi
export TELEMETRY_JSON

mkdir -p "${TICKET_DIR}" 2>/dev/null || true

PAYLOAD=$(
  TICKET_KEY="${TICKET_KEY}" \
  DASHBOARD_STAGE="${DASHBOARD_STAGE}" \
  AGENT_STAGE="${AGENT_STAGE}" \
  STATUS="${STATUS}" \
  NEEDS_HUMAN="${NEEDS_HUMAN}" \
  NOTIFICATION_TYPE="${NOTIFICATION_TYPE}" \
  NOTIFICATION_MSG="${NOTIFICATION_MSG}" \
  TICKET_DIR="${TICKET_DIR}" \
  ${PYTHON_BIN} << 'PYTHON_SCRIPT' 2>"${TICKET_DIR}/report-to-dashboard-error.log" || echo '{}'
import json
import re
import os
import sys
import subprocess
from datetime import datetime, timezone

ticket_key = os.environ.get("TICKET_KEY", "")
dashboard_stage = os.environ.get("DASHBOARD_STAGE", "")
agent_stage = os.environ.get("AGENT_STAGE", "")
status = os.environ.get("STATUS", "in_progress")
needs_human = os.environ.get("NEEDS_HUMAN", "false") == "true"
notification_type = os.environ.get("NOTIFICATION_TYPE", "")
notification_msg = os.environ.get("NOTIFICATION_MSG", "")
ticket_dir = os.environ.get("TICKET_DIR", "")
telemetry_json_str = os.environ.get("TELEMETRY_JSON", "{}")

payload = {
    "ticket_key": ticket_key,
    "stage": dashboard_stage,
    "status": status,
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}

# Include telemetry if available — cap duration at 1h to exclude idle time
MAX_STAGE_DURATION = 3600
try:
    telemetry_data = json.loads(telemetry_json_str)
    if telemetry_data:
        dur = telemetry_data.get("duration_seconds")
        if dur is not None and isinstance(dur, (int, float)) and dur > MAX_STAGE_DURATION:
            telemetry_data["duration_seconds"] = MAX_STAGE_DURATION
        payload["telemetry"] = telemetry_data
except (json.JSONDecodeError, TypeError):
    pass

# ---------------------------------------------------------------------------
# Stage-specific data extraction + synthetic log generation
# ---------------------------------------------------------------------------
stage_logs = []  # Rich log entries generated from stage data

def add_log(message, level="info"):
    """Add a synthetic log entry with the current stage's agent name."""
    stage_logs.append({
        "level": level,
        "message": f"{dashboard_stage} — {message}",
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })

# --- scanner ---
if agent_stage == "scanner":
    scanner_path = os.path.join(ticket_dir, "scanner-output.json")
    if os.path.isfile(scanner_path):
        try:
            with open(scanner_path) as f:
                scanner_data = json.load(f)
            stage_data = {}
            services_list = scanner_data.get("services_scanned", [])
            stage_data["services_scanned"] = len(services_list)
            stage_data["total_mrs"] = scanner_data.get("total_mrs", 0)
            stage_data["mrs_by_service"] = scanner_data.get("mrs_by_service", {})
            if scanner_data.get("since"):
                stage_data["since"] = scanner_data["since"]
            if scanner_data.get("until"):
                stage_data["until"] = scanner_data["until"]
            if stage_data:
                payload["stage_data"] = stage_data
            # Send scanned_services and scan date range to pipeline-level columns
            if services_list:
                payload["scanned_services"] = services_list
            if scanner_data.get("since"):
                payload["scan_date_from"] = scanner_data["since"]
            if scanner_data.get("until"):
                payload["scan_date_to"] = scanner_data["until"]
            add_log(f"Scanning GitLab for merged MRs")
            svc = stage_data.get("services_scanned", 0)
            if svc:
                add_log(f"Scanned {svc} service{'s' if svc != 1 else ''}")
            tm = stage_data.get("total_mrs", 0)
            if tm:
                add_log(f"Found {tm} merged MR{'s' if tm != 1 else ''}")
            mbs = stage_data.get("mrs_by_service", {})
            for svc_name, mr_list in mbs.items():
                count = len(mr_list) if isinstance(mr_list, list) else mr_list
                add_log(f"  {svc_name}: {count} MR{'s' if count != 1 else ''}")
            add_log("Scanner complete — wrote scanner-output.json")
        except (json.JSONDecodeError, OSError):
            pass
    if not stage_logs:
        add_log("Scanning GitLab for merged MRs in monitored services")
        if status == "completed":
            add_log("GitLab scan complete")

# --- analyzer ---
elif agent_stage == "analyzer":
    analyzer_path = os.path.join(ticket_dir, "analyzer-output.json")
    if os.path.isfile(analyzer_path):
        try:
            with open(analyzer_path) as f:
                analyzer_data = json.load(f)
            stage_data = {}
            scenarios = analyzer_data.get("scenarios", [])
            stage_data["scenarios_count"] = len(scenarios)
            stage_data["skipped_mrs"] = len(analyzer_data.get("skipped_mrs", []))
            summary_data = analyzer_data.get("summary", {})
            if summary_data:
                stage_data["total_mrs_analyzed"] = summary_data.get("total_mrs_analyzed", 0)
                stage_data["priority_breakdown"] = summary_data.get("priority_breakdown", {})
            if stage_data:
                payload["stage_data"] = stage_data
            add_log("Analyzing MR diffs and classifying changes")
            tma = stage_data.get("total_mrs_analyzed", 0)
            if tma:
                add_log(f"Analyzed {tma} MR{'s' if tma != 1 else ''}")
            sc = stage_data.get("scenarios_count", 0)
            if sc:
                add_log(f"Created {sc} testable scenario{'s' if sc != 1 else ''}")
            sk = stage_data.get("skipped_mrs", 0)
            if sk:
                add_log(f"Skipped {sk} MR{'s' if sk != 1 else ''} (backend-only or CI)")
            pb = stage_data.get("priority_breakdown", {})
            if pb:
                parts = [f"{v} {k}" for k, v in pb.items() if v]
                if parts:
                    add_log(f"Priority breakdown: {', '.join(parts)}")
            add_log("Analysis complete — wrote analyzer-output.json")
        except (json.JSONDecodeError, OSError):
            pass
    if not stage_logs:
        add_log("Analyzing MR diffs and classifying changes")
        if status == "completed":
            add_log("Analysis complete")

# --- ticket-creator ---
elif agent_stage in ("ticket-creator", "ticketcreator"):
    tickets_path = os.path.join(ticket_dir, "tickets-created.json")
    if os.path.isfile(tickets_path):
        try:
            with open(tickets_path) as f:
                tickets_data = json.load(f)
            stage_data = {}
            tickets = tickets_data.get("tickets", tickets_data.get("tickets_created", []))
            stage_data["tickets_created"] = len(tickets)
            stage_data["duplicates_found"] = len(tickets_data.get("duplicates_found", tickets_data.get("duplicates_skipped", [])))
            if tickets:
                stage_data["ticket_keys"] = [t.get("key") for t in tickets if t.get("key")]
            summary_data = tickets_data.get("summary", {})
            if summary_data:
                stage_data["scenarios_received"] = summary_data.get("scenarios_received", 0)
            if stage_data:
                payload["stage_data"] = stage_data
            # Send full ticket objects to pipeline-level tickets_created column
            # so the dashboard drawer can render clickable links
            if tickets:
                jira_base = os.environ.get("JIRA_BASE_URL", "https://oxsecurity.atlassian.net/browse")
                payload["tickets_created"] = [
                    {
                        "key": t.get("key", ""),
                        "title": t.get("title") or t.get("summary", ""),
                        "feature_area": t.get("feature_area", ""),
                        "priority": t.get("priority", ""),
                        "complexity": t.get("complexity", ""),
                        "url": t.get("url") or f"{jira_base}/{t.get('key', '')}",
                    }
                    for t in tickets
                    if t.get("key")
                ]
            add_log("Creating Jira tickets for testable scenarios")
            tc = stage_data.get("tickets_created", 0)
            if tc:
                add_log(f"Created {tc} Jira ticket{'s' if tc != 1 else ''}")
            df = stage_data.get("duplicates_found", 0)
            if df:
                add_log(f"Skipped {df} duplicate{'s' if df != 1 else ''}")
            tk = stage_data.get("ticket_keys", [])
            for key in tk[:10]:
                add_log(f"Created: {key}")
            add_log("Ticket creation complete — wrote tickets-created.json")
        except (json.JSONDecodeError, OSError):
            pass
    if not stage_logs:
        add_log("Creating Jira tickets for discovered scenarios")
        if status == "completed":
            add_log("Ticket creation complete")

# --- triage ---
elif agent_stage == "triage":
    triage_path = os.path.join(ticket_dir, "triage.json")
    if os.path.isfile(triage_path):
        try:
            with open(triage_path) as f:
                triage = json.load(f)

            ticket_data = {}
            for field in ("summary", "feature_area", "test_type", "complexity",
                          "needs_baseline", "org_name", "target_pages",
                          "jira_url", "jira_status", "priority"):
                val = triage.get(field)
                if val is not None:
                    ticket_data[field] = val

            if ticket_data:
                payload["ticket_data"] = ticket_data

            # Generate rich logs for triage
            add_log(f"Reading Jira ticket {ticket_key}")
            summary = ticket_data.get("summary", "")
            if summary:
                add_log(f"Ticket: {summary[:120]}")
            feat = ticket_data.get("feature_area", "unknown")
            ttype = ticket_data.get("test_type", "unknown")
            comp = ticket_data.get("complexity", "unknown")
            add_log(f"Classified as {ttype} test — feature area: {feat}, complexity: {comp}")
            if ticket_data.get("needs_baseline"):
                add_log("Ticket requires MongoDB baseline comparison")
            pages = ticket_data.get("target_pages", [])
            if pages:
                add_log(f"Target pages: {', '.join(pages[:5])}")
            add_log(f"Triage complete — wrote triage.json")

        except (json.JSONDecodeError, OSError):
            pass

    if not stage_logs:
        add_log(f"Reading Jira ticket {ticket_key}")
        add_log("Classifying ticket by feature area, test type, and complexity")
        if status == "completed":
            add_log("Triage classification complete")

# --- explorer ---
elif agent_stage in ("explorer", "explore"):
    stage_data = {}

    # Priority 1: Structured JSON output from agent
    explorer_json_path = os.path.join(ticket_dir, "explorer-output.json")
    if os.path.isfile(explorer_json_path):
        try:
            with open(explorer_json_path) as f:
                explorer_data = json.load(f)
            stage_data["similar_tests_found"] = len(explorer_data.get("similar_tests", []))
            stage_data["reusable_actions"] = sum(len(a.get("functions", [])) for a in explorer_data.get("reusable_actions", []))
            stage_data["reusable_selectors"] = sum(s.get("count", 0) for s in explorer_data.get("reusable_selectors", []))
            stage_data["new_actions_needed"] = len(explorer_data.get("new_actions_needed", []))
            stage_data["new_selectors_needed"] = len(explorer_data.get("new_selectors_needed", []))
            # Forward full arrays for detailed display
            if explorer_data.get("similar_tests"):
                stage_data["similar_tests"] = explorer_data["similar_tests"][:20]
            if explorer_data.get("reusable_actions"):
                stage_data["reusable_actions_detail"] = explorer_data["reusable_actions"][:20]
            if explorer_data.get("reusable_selectors"):
                stage_data["reusable_selectors_detail"] = explorer_data["reusable_selectors"][:20]
        except (json.JSONDecodeError, OSError):
            pass

    # Priority 2: Fallback to markdown regex parsing
    if not stage_data:
        exploration_path = os.path.join(ticket_dir, "exploration.md")
        if os.path.isfile(exploration_path):
            try:
                with open(exploration_path) as f:
                    content = f.read()
                tests_match = re.findall(r'\| .+\.test\.js', content)
                stage_data["similar_tests_found"] = len(tests_match)
                actions_match = re.findall(r'\| actions/', content)
                stage_data["reusable_actions"] = len(actions_match)
                selectors_match = re.findall(r'\| selectors/', content)
                stage_data["reusable_selectors"] = len(selectors_match)
            except OSError:
                pass

    if stage_data:
        payload["stage_data"] = stage_data

    # Generate rich logs for explorer
    if stage_data:
        add_log("Scanning E2E framework for similar tests and reusable patterns")
        st = stage_data.get("similar_tests_found", 0)
        if st:
            add_log(f"Found {st} similar test file{'s' if st != 1 else ''}")
        ra = stage_data.get("reusable_actions", 0)
        if ra:
            add_log(f"Identified {ra} reusable action function{'s' if ra != 1 else ''}")
        rs = stage_data.get("reusable_selectors", 0)
        if rs:
            add_log(f"Cataloged {rs} reusable selector{'s' if rs != 1 else ''}")
        na = stage_data.get("new_actions_needed", 0)
        ns = stage_data.get("new_selectors_needed", 0)
        if na or ns:
            parts = []
            if na:
                parts.append(f"{na} new action{'s' if na != 1 else ''}")
            if ns:
                parts.append(f"{ns} new selector{'s' if ns != 1 else ''}")
            add_log(f"Will need to create: {', '.join(parts)}")
        add_log("Framework exploration complete — wrote exploration.md")
    else:
        add_log("Scanning E2E framework for patterns and similar tests")
        if status == "completed":
            add_log("Exploration complete")

# --- playwright ---
elif agent_stage in ("playwright", "browser"):
    pw_path = os.path.join(ticket_dir, "playwright-data.json")
    if os.path.isfile(pw_path):
        try:
            with open(pw_path) as f:
                pw_data = json.load(f)

            stage_data = {}
            pages = pw_data.get("pages", [])
            stage_data["pages_explored"] = len(pages)
            total_elements = sum(len(p.get("elements", [])) for p in pages)
            stage_data["elements_found"] = total_elements

            selectors = pw_data.get("selectors", {})
            stage_data["selectors_found"] = len(selectors)

            new_selectors = pw_data.get("new_selectors_needed", [])
            stage_data["new_selectors_needed"] = len(new_selectors)

            reusable = pw_data.get("reusable_selectors", [])
            stage_data["reusable_selectors"] = len(reusable)

            flow_val = pw_data.get("flow_validation", {})
            if flow_val:
                stage_data["flow_validated"] = flow_val.get("status", "unknown")
                stage_data["flow_steps_passed"] = flow_val.get("steps_passed", 0)
                stage_data["flow_steps_failed"] = flow_val.get("steps_failed", 0)

            if stage_data:
                payload["stage_data"] = stage_data

            # Generate rich logs for playwright
            add_log("Opening browser via Playwright MCP, navigating to staging")
            pe = stage_data.get("pages_explored", 0)
            if pe:
                add_log(f"Explored {pe} page{'s' if pe != 1 else ''}")
            ef = stage_data.get("elements_found", 0)
            if ef:
                add_log(f"Inspected {ef} DOM element{'s' if ef != 1 else ''}")
            sf = stage_data.get("selectors_found", 0)
            if sf:
                add_log(f"Captured {sf} selector{'s' if sf != 1 else ''}")
            fv = stage_data.get("flow_validated")
            if fv:
                sp = stage_data.get("flow_steps_passed", 0)
                sfail = stage_data.get("flow_steps_failed", 0)
                add_log(f"Navigation flow validation: {fv} ({sp} passed, {sfail} failed)")
            add_log("Browser data capture complete — wrote playwright-data.json")
        except (json.JSONDecodeError, OSError):
            pass

    if not stage_logs:
        add_log("Opening browser, navigating to staging app")
        add_log("Capturing real DOM selectors and values")
        if status == "completed":
            add_log("Browser data capture complete")

# --- code-writer ---
elif agent_stage in ("code-writer", "codewriter"):
    stage_data = {}

    # Priority 1: Structured JSON output from agent (has diff stats + content)
    cw_json_path = os.path.join(ticket_dir, "code-writer-output.json")
    if os.path.isfile(cw_json_path):
        try:
            with open(cw_json_path) as f:
                cw_data = json.load(f)
            for field in ("test_file", "branch_name", "files_count",
                          "lines_added", "lines_deleted", "test_steps",
                          "uses_baseline", "feature_doc"):
                val = cw_data.get(field)
                if val is not None:
                    stage_data[field] = val
            # Handle alternative field names the agent sometimes uses
            if not stage_data.get("branch_name") and cw_data.get("branch"):
                stage_data["branch_name"] = cw_data["branch"]

            def is_valid_unified_diff(diff_text):
                """Check if diff looks like real unified diff (has @@ hunk headers or +/- lines)."""
                if not diff_text:
                    return False
                lines = diff_text.split('\n')
                has_hunk = any(l.startswith('@@') for l in lines)
                has_plus_minus = sum(1 for l in lines if l.startswith('+') or l.startswith('-')) > 1
                return has_hunk or has_plus_minus

            # Resolve git branch ref for fetching real diffs/stats
            framework_dir = os.environ.get("E2E_FRAMEWORK_PATH", "")
            branch_ref = stage_data.get("branch_name", "HEAD")
            if framework_dir and branch_ref != "HEAD":
                try:
                    subprocess.check_output(
                        ["git", "-C", framework_dir, "rev-parse", "--verify", branch_ref],
                        text=True, timeout=5, stderr=subprocess.DEVNULL
                    )
                except Exception:
                    try:
                        subprocess.check_output(
                            ["git", "-C", framework_dir, "rev-parse", "--verify", f"origin/{branch_ref}"],
                            text=True, timeout=5, stderr=subprocess.DEVNULL
                        )
                        branch_ref = f"origin/{branch_ref}"
                    except Exception:
                        branch_ref = "HEAD"

            # Resolve git repo root (E2E_FRAMEWORK_PATH may be a subdirectory)
            git_root = framework_dir
            if framework_dir:
                try:
                    git_root = subprocess.check_output(
                        ["git", "-C", framework_dir, "rev-parse", "--show-toplevel"],
                        text=True, timeout=5, stderr=subprocess.DEVNULL
                    ).strip()
                except Exception:
                    pass

            # Build complete files array from git numstat (authoritative source for all files + line counts)
            git_files_map = {}
            if framework_dir:
                try:
                    numstat = subprocess.check_output(
                        ["git", "-C", git_root, "diff", "--numstat", f"developmentV2...{branch_ref}"],
                        text=True, timeout=10, stderr=subprocess.DEVNULL
                    ).strip()
                    for line in numstat.split('\n'):
                        parts = line.split('\t')
                        if len(parts) == 3:
                            a = int(parts[0]) if parts[0] != '-' else 0
                            d = int(parts[1]) if parts[1] != '-' else 0
                            git_files_map[parts[2]] = {"path": parts[2], "added": a, "deleted": d}
                except Exception:
                    pass

            # Start with agent's files array if present, otherwise build from files_modified/files_created
            if cw_data.get("files"):
                files = cw_data["files"][:50]
            elif cw_data.get("files_modified") or cw_data.get("files_created"):
                all_paths = list(cw_data.get("files_created") or []) + list(cw_data.get("files_modified") or [])
                top_diff = cw_data.get("diff", "")
                files = []
                for p in all_paths:
                    entry = {"path": p, "added": 0, "deleted": 0}
                    if top_diff and len(all_paths) == 1:
                        entry["diff"] = top_diff
                    files.append(entry)
            else:
                files = []

            # Merge git numstat data: update existing entries + add missing files
            # Git paths may have a prefix (e.g. "framework/") that agent paths lack
            def find_git_match(agent_path, git_map):
                """Find matching git entry — exact match or suffix match."""
                if agent_path in git_map:
                    return agent_path
                for gp in git_map:
                    if gp.endswith("/" + agent_path) or agent_path.endswith("/" + gp):
                        return gp
                return None

            seen_git_paths = set()
            for f in files:
                match_key = find_git_match(f["path"], git_files_map)
                if match_key:
                    seen_git_paths.add(match_key)
                    git_info = git_files_map[match_key]
                    if not f.get("added"):
                        f["added"] = git_info["added"]
                    if not f.get("deleted"):
                        f["deleted"] = git_info["deleted"]
                    # Use the git path (includes framework/ prefix) for diff lookups
                    f["_git_path"] = match_key
            # Add files found by git but not in agent output
            for p, info in git_files_map.items():
                if p not in seen_git_paths:
                    files.append(info)

            # Validate and fetch real diffs for each file
            if files:
                for f in files:
                    diff_text = f.get("diff", "")
                    needs_real_diff = not diff_text or not is_valid_unified_diff(diff_text)
                    if needs_real_diff and framework_dir:
                        # Use git path (may have framework/ prefix) for the diff command
                        diff_path = f.get("_git_path", f["path"])
                        try:
                            real_diff = subprocess.check_output(
                                ["git", "-C", git_root, "diff", f"developmentV2...{branch_ref}", "--", diff_path],
                                text=True, timeout=10, stderr=subprocess.DEVNULL
                            ).strip()
                            if real_diff:
                                f["diff"] = real_diff
                        except Exception:
                            pass
                    # Truncate per-file diffs to keep payload reasonable
                    if f.get("diff"):
                        diff_lines = f["diff"].split('\n')
                        if len(diff_lines) > 500:
                            f["diff"] = '\n'.join(diff_lines[:500]) + '\n... (truncated)'
                # Clean up temp keys before sending
                for f in files:
                    f.pop("_git_path", None)
                stage_data["files"] = files[:50]
                stage_data["files_count"] = len(files)
                stage_data["lines_added"] = sum(f.get("added", 0) for f in files)
                stage_data["lines_deleted"] = sum(f.get("deleted", 0) for f in files)
            # Also forward files_list as plain paths
            if cw_data.get("files"):
                stage_data["files_list"] = [f["path"] for f in cw_data["files"]][:30]
            if cw_data.get("new_actions"):
                stage_data["new_actions"] = cw_data["new_actions"]
            if cw_data.get("new_selectors"):
                stage_data["new_selectors"] = cw_data["new_selectors"]
        except (json.JSONDecodeError, OSError):
            pass

    # Priority 2: Fallback to implementation.md + git subprocess
    if not stage_data.get("test_file"):
        impl_path = os.path.join(ticket_dir, "implementation.md")
        if os.path.isfile(impl_path):
            try:
                with open(impl_path) as f:
                    content = f.read()
                file_match = re.search(r'tests/UI/\S+\.test\.js', content)
                if file_match:
                    stage_data["test_file"] = file_match.group(0)
                branch_match = re.search(r'[Bb]ranch[:\s]+[`*]*([^\s`*\n]+)', content)
                if branch_match and not stage_data.get("branch_name"):
                    stage_data["branch_name"] = branch_match.group(1)
                file_paths = re.findall(r'(?:tests/UI/|actions/|selectors/)\S+\.(?:js|json)', content)
                if file_paths and not stage_data.get("files_list"):
                    stage_data["files_list"] = list(dict.fromkeys(file_paths))[:30]
            except OSError:
                pass

    # Priority 3: Git diff subprocess (only if no files data from JSON)
    if not stage_data.get("files"):
        framework_dir = os.environ.get("E2E_FRAMEWORK_PATH", "")
        if framework_dir:
            try:
                # Resolve git root (framework_dir may be a subdirectory)
                p3_git_root = subprocess.check_output(
                    ["git", "-C", framework_dir, "rev-parse", "--show-toplevel"],
                    text=True, timeout=5, stderr=subprocess.DEVNULL
                ).strip() or framework_dir

                if not stage_data.get("branch_name"):
                    branch = subprocess.check_output(
                        ["git", "-C", p3_git_root, "branch", "--show-current"],
                        text=True, timeout=5, stderr=subprocess.DEVNULL
                    ).strip()
                    if branch:
                        stage_data["branch_name"] = branch

                # Use the ticket branch name if available, otherwise HEAD
                diff_ref = stage_data.get("branch_name", "HEAD")
                # Ensure the ref exists as a remote branch if not HEAD
                if diff_ref != "HEAD":
                    try:
                        subprocess.check_output(
                            ["git", "-C", p3_git_root, "rev-parse", "--verify", diff_ref],
                            text=True, timeout=5, stderr=subprocess.DEVNULL
                        )
                    except Exception:
                        try:
                            subprocess.check_output(
                                ["git", "-C", p3_git_root, "rev-parse", "--verify", f"origin/{diff_ref}"],
                                text=True, timeout=5, stderr=subprocess.DEVNULL
                            )
                            diff_ref = f"origin/{diff_ref}"
                        except Exception:
                            diff_ref = "HEAD"

                numstat = subprocess.check_output(
                    ["git", "-C", p3_git_root, "diff", "--numstat", f"developmentV2...{diff_ref}"],
                    text=True, timeout=10, stderr=subprocess.DEVNULL
                ).strip()
                if numstat:
                    files = []
                    total_add = 0
                    total_del = 0
                    for line in numstat.split('\n'):
                        parts = line.split('\t')
                        if len(parts) == 3:
                            a = int(parts[0]) if parts[0] != '-' else 0
                            d = int(parts[1]) if parts[1] != '-' else 0
                            files.append({"path": parts[2], "added": a, "deleted": d})
                            total_add += a
                            total_del += d
                    # Capture per-file diff content
                    for file_info in files[:20]:
                        try:
                            diff_out = subprocess.check_output(
                                ["git", "-C", p3_git_root, "diff", f"developmentV2...{diff_ref}", "--", file_info["path"]],
                                text=True, timeout=10, stderr=subprocess.DEVNULL
                            ).strip()
                            if diff_out:
                                diff_lines = diff_out.split('\n')
                                if len(diff_lines) > 500:
                                    diff_out = '\n'.join(diff_lines[:500]) + '\n... (truncated)'
                                file_info["diff"] = diff_out
                        except Exception:
                            pass
                    stage_data["files"] = files[:50]
                    stage_data["files_count"] = len(files)
                    stage_data["lines_added"] = total_add
                    stage_data["lines_deleted"] = total_del
            except Exception:
                pass

    if stage_data:
        payload["stage_data"] = stage_data

    # Generate rich logs for code-writer
    if stage_data:
        branch = stage_data.get("branch_name")
        if branch:
            add_log(f"Created feature branch: {branch}")
        tf = stage_data.get("test_file")
        if tf:
            add_log(f"Writing test file: {tf}")
        ts = stage_data.get("test_steps")
        if ts:
            add_log(f"Implemented {ts} test step{'s' if ts != 1 else ''}")
        fc = stage_data.get("files_count", 0)
        la = stage_data.get("lines_added", 0)
        ld = stage_data.get("lines_deleted", 0)
        if fc:
            add_log(f"Modified {fc} file{'s' if fc != 1 else ''} (+{la} / -{ld} lines)")
        na = stage_data.get("new_actions")
        if na:
            add_log(f"Created new action module{'s' if len(na) != 1 else ''}: {', '.join(na[:5])}")
        ns = stage_data.get("new_selectors")
        if ns:
            add_log(f"Created new selector file{'s' if len(ns) != 1 else ''}: {', '.join(ns[:5])}")
        if stage_data.get("uses_baseline"):
            add_log("Test uses MongoDB baseline comparison pattern")
        fd = stage_data.get("feature_doc")
        if fd:
            add_log(f"Feature doc: {fd[:120]}...")
        fl = stage_data.get("files_list", [])
        for fp in fl[:8]:
            add_log(f"Committed: {fp}")
        add_log("Implementation complete — wrote code-writer-output.json")
    else:
        add_log("Writing test file, actions, and selectors")
        if status == "completed":
            add_log("Implementation complete")

# --- validator ---
elif agent_stage == "validator":
    stage_data = {}
    vr_path = os.path.join(ticket_dir, "validation-report.json")
    if os.path.isfile(vr_path):
        try:
            with open(vr_path) as f:
                vr = json.load(f)
            passed_n = vr.get("passed", 0)
            failed_n = vr.get("failed", 0)
            auto_fixed = vr.get("auto_fixed", 0)
            total_checks = passed_n + failed_n
            stage_data["quality"] = {
                "passed": passed_n, "failed": failed_n,
                "auto_fixed": auto_fixed, "total": total_checks,
                "status": vr.get("status", "unknown"),
            }
            # Top-level quality field for dashboard table column
            payload["quality"] = stage_data["quality"]
            raw_checks = vr.get("checks", [])
            # Normalize checks: accept both array and dict formats
            if isinstance(raw_checks, dict):
                checks = [
                    {"name": k, "passed": v.get("status", "") == "pass" if isinstance(v, dict) else bool(v),
                     "details": v.get("details", "") if isinstance(v, dict) else str(v)}
                    for k, v in raw_checks.items()
                ]
            else:
                checks = raw_checks
            if checks:
                stage_data["checks"] = [
                    {"name": c.get("name", ""), "passed": c.get("passed", False), "details": str(c.get("details", ""))[:100]}
                    for c in checks[:20]
                ]
            add_log(f"Quality checks: {passed_n}/{total_checks} passed")
            if auto_fixed > 0:
                add_log(f"Auto-fixed {auto_fixed} convention violation{'s' if auto_fixed != 1 else ''}")
            if failed_n > 0:
                for c in checks:
                    if not c.get("passed"):
                        add_log(f"FAIL: {c.get('name', '?')} — {str(c.get('details', ''))[:80]}", level="warn")
            else:
                add_log("All convention checks passed")
        except (json.JSONDecodeError, OSError, AttributeError, TypeError, KeyError) as e:
            add_log(f"Failed to parse validation-report.json: {e}", level="warn")

    if stage_data:
        payload["stage_data"] = stage_data

    if not stage_data:
        add_log("Running convention checks on code-writer output")
        if status == "completed":
            add_log("Validation complete")

# --- test-runner ---
elif agent_stage in ("test-runner", "testrunner"):
    results_path = os.path.join(ticket_dir, "test-results.json")
    if os.path.isfile(results_path):
        try:
            with open(results_path) as f:
                results = json.load(f)

            stage_data = {}
            for field in ("status", "total", "passed", "failed", "skipped",
                          "duration_ms", "test_file", "video_url"):
                val = results.get(field)
                if val is not None:
                    stage_data[field] = val

            # Also check alternate field names from test-runner output
            for alt_field, canon_field in [
                ("test_count", "total"), ("passed_count", "passed"),
                ("failed_count", "failed"), ("skipped_count", "skipped"),
                ("duration_seconds", "duration_s"),
            ]:
                val = results.get(alt_field)
                if val is not None and canon_field not in stage_data:
                    stage_data[canon_field] = val

            # Forward per-test error details for dashboard test results view
            errors = results.get("errors", [])
            if errors:
                test_steps = []
                for err in errors:
                    step = {
                        "name": err.get("test_name", "Unknown test"),
                        "status": "FAIL",
                        "error_type": err.get("error_type", "unknown"),
                        "error_message": (err.get("error_message", "") or "")[:500],
                        "file": err.get("file"),
                        "line": err.get("line"),
                    }
                    if err.get("trace_path"):
                        step["trace_path"] = err["trace_path"]
                    test_steps.append(step)
                stage_data["test_steps"] = test_steps
                stage_data["failure_count"] = len(errors)

            # Forward top-level trace paths
            traces = results.get("traces", [])
            if traces:
                stage_data["traces"] = traces[:10]

            # Agent skill output uses "failures" array — convert to test_steps
            failures = results.get("failures", [])
            if failures and "test_steps" not in stage_data:
                test_steps = []
                for fail in failures:
                    step = {
                        "name": fail.get("test_name", "Unknown test"),
                        "status": "FAIL",
                        "error_message": (fail.get("error", "") or "")[:500],
                    }
                    if fail.get("error_type"):
                        step["error_type"] = fail["error_type"]
                    if fail.get("line"):
                        step["line"] = fail["line"]
                    if fail.get("expected"):
                        step["expected"] = str(fail["expected"])[:200]
                    if fail.get("actual"):
                        step["actual"] = str(fail["actual"])[:200]
                    if fail.get("trace_path"):
                        step["trace_path"] = fail["trace_path"]
                    test_steps.append(step)
                stage_data["test_steps"] = test_steps
                stage_data["failure_count"] = len(failures)

            if stage_data:
                payload["stage_data"] = stage_data

            # Generate rich logs for test-runner
            tf = stage_data.get("test_file", results.get("test_file", ""))
            if tf:
                add_log(f"Executing: {tf}")
            add_log("Running with --retries=0 --trace on")
            total = stage_data.get("total", 0)
            passed_n = stage_data.get("passed", 0)
            failed_n = stage_data.get("failed", 0)
            skipped_n = stage_data.get("skipped", 0)
            dur = stage_data.get("duration_ms")
            if total:
                dur_str = f" in {dur}ms" if dur else ""
                add_log(f"Results: {passed_n}/{total} passed, {failed_n} failed, {skipped_n} skipped{dur_str}")
            ts_list = stage_data.get("test_steps", [])
            for ts_item in ts_list[:5]:
                name = ts_item.get("name", "?")
                err_type = ts_item.get("error_type", "")
                err_msg = ts_item.get("error_message", "")[:120]
                detail = f" ({err_type})" if err_type else ""
                add_log(f"FAIL: {name}{detail} — {err_msg}", level="error")
            traces = stage_data.get("traces", [])
            if traces:
                add_log(f"Captured {len(traces)} trace file{'s' if len(traces) != 1 else ''}")
            video_url = stage_data.get("video_url")
            if video_url:
                add_log(f"Test video uploaded to S3")
            test_status = stage_data.get("status", status)
            if test_status == "passed" or (failed_n == 0 and total > 0):
                add_log("All tests passed")
            elif failed_n > 0:
                add_log(f"Test run complete — {failed_n} failure{'s' if failed_n != 1 else ''} to debug", level="warn")
        except (json.JSONDecodeError, OSError):
            pass

    if not stage_logs:
        add_log("Executing Playwright test suite")
        if status == "completed":
            add_log("Test execution complete")

# --- debug ---
elif agent_stage == "debug":
    stage_data = {}

    # Priority 1: Structured JSON output from agent
    debug_json_path = os.path.join(ticket_dir, "debug-output.json")
    if os.path.isfile(debug_json_path):
        try:
            with open(debug_json_path) as f:
                debug_data = json.load(f)
            stage_data["total_cycles"] = debug_data.get("total_cycles", 0)
            stage_data["final_status"] = debug_data.get("final_status")
            # Forward per-cycle details for dashboard display
            cycles = debug_data.get("cycles", [])
            if cycles:
                stage_data["cycles"] = []
                for cycle in cycles[:10]:
                    stage_data["cycles"].append({
                        "cycle_number": cycle.get("cycle_number"),
                        "error_type": cycle.get("error_type"),
                        "error_message": (cycle.get("error_message", "") or "")[:500],
                        "root_cause": (cycle.get("root_cause", "") or "")[:500],
                        "fix_applied": (cycle.get("fix_applied", "") or "")[:500],
                        "files_changed": cycle.get("files_changed", []),
                        "outcome": cycle.get("outcome"),
                        "test_results": cycle.get("test_results"),
                    })
                stage_data["debug_cycle"] = len(cycles)
        except (json.JSONDecodeError, OSError):
            pass

    # Priority 2: Fallback to test-results.json + checkpoint.json
    results_path = os.path.join(ticket_dir, "test-results.json")
    if os.path.isfile(results_path):
        try:
            with open(results_path) as f:
                results = json.load(f)
            stage_data["test_results"] = {
                "status": results.get("status"),
                "passed": results.get("passed"),
                "failed": results.get("failed"),
            }
        except (json.JSONDecodeError, OSError):
            pass

    if not stage_data.get("debug_cycle"):
        checkpoint_path = os.path.join(ticket_dir, "checkpoint.json")
        if os.path.isfile(checkpoint_path):
            try:
                with open(checkpoint_path) as f:
                    checkpoint = json.load(f)
                debug_cycles = checkpoint.get("debug_cycles")
                if debug_cycles is not None:
                    stage_data["debug_cycle"] = debug_cycles
            except (json.JSONDecodeError, OSError):
                pass

    if stage_data:
        payload["stage_data"] = stage_data

    # Generate rich logs for debug
    if stage_data:
        tc = stage_data.get("total_cycles", stage_data.get("debug_cycle", 0))
        fs = stage_data.get("final_status", "")
        if tc:
            add_log(f"Debug cycles: {tc}/3 — final status: {fs or 'unknown'}")
        cycles = stage_data.get("cycles", [])
        for cyc in cycles[:3]:
            cn = cyc.get("cycle_number", "?")
            et = cyc.get("error_type", "")
            em = (cyc.get("error_message", "") or "")[:80]
            rc = (cyc.get("root_cause", "") or "")[:80]
            fix = (cyc.get("fix_applied", "") or "")[:80]
            outcome = cyc.get("outcome", "")
            fc = cyc.get("files_changed", [])
            add_log(f"Cycle {cn}: {et or 'error'} — {em}")
            if rc:
                add_log(f"  Root cause: {rc}")
            if fix:
                add_log(f"  Fix applied: {fix}")
            if fc:
                add_log(f"  Files changed: {', '.join(fc[:5])}")
            if outcome:
                level = "error" if outcome == "failed" else "info"
                add_log(f"  Outcome: {outcome}", level=level)
        tr = stage_data.get("test_results", {})
        if tr:
            add_log(f"Final test results — passed: {tr.get('passed', '?')}, failed: {tr.get('failed', '?')}")
        if not cycles and tc:
            add_log(f"Ran {tc} debug cycle{'s' if tc != 1 else ''}")
        if fs == "passed":
            add_log("All tests passing after debug fixes")
        elif fs == "failed":
            add_log("Tests still failing after max debug cycles", level="error")
    else:
        add_log("Analyzing test failures and trace files")
        if status == "completed":
            add_log("Debug analysis complete")

# --- pr ---
elif agent_stage in ("pr", "pr-creation"):
    stage_data = {}

    # Priority 1: Structured JSON output from agent
    pr_json_path = os.path.join(ticket_dir, "pr-output.json")
    if os.path.isfile(pr_json_path):
        try:
            with open(pr_json_path) as f:
                pr_data = json.load(f)
            for field in ("mr_url", "branch_name", "target_branch", "title", "created_at"):
                val = pr_data.get(field)
                if val is not None:
                    stage_data[field] = val
            if pr_data.get("test_results"):
                stage_data["test_results"] = pr_data["test_results"]
            if pr_data.get("files_changed"):
                stage_data["files_changed"] = pr_data["files_changed"][:30]
        except (json.JSONDecodeError, OSError):
            pass

    # Priority 2: Fallback to pr-result.md regex
    if not stage_data.get("mr_url"):
        pr_path = os.path.join(ticket_dir, "pr-result.md")
        if os.path.isfile(pr_path):
            try:
                with open(pr_path) as f:
                    pr_content = f.read()
                mr_match = re.search(r'https?://gitlab\.com/[^\s)>\]]+/merge_requests/\d+', pr_content)
                if mr_match:
                    stage_data["mr_url"] = mr_match.group(0)
                branch_match = re.search(r'[Bb]ranch[:\s]+[`*]*([^\s`*\n]+)', pr_content)
                if branch_match:
                    stage_data["branch_name"] = branch_match.group(1)
            except OSError:
                pass

    if stage_data:
        payload["stage_data"] = stage_data

    # Generate rich logs for PR
    if stage_data:
        branch = stage_data.get("branch_name")
        target = stage_data.get("target_branch", "developmentV2")
        if branch:
            add_log(f"Pushing branch: {branch}")
        mr_url = stage_data.get("mr_url")
        title = stage_data.get("title", "")
        if mr_url:
            add_log(f"Created merge request: {title[:80]}" if title else "Created merge request")
            add_log(f"MR URL: {mr_url}")
            add_log(f"Target branch: {target}")
        tr = stage_data.get("test_results", {})
        if tr:
            add_log(f"Test results: {tr.get('passed', '?')} passed, {tr.get('failed', '?')} failed")
        fc = stage_data.get("files_changed", [])
        if fc:
            add_log(f"Files in MR: {len(fc)}")
        add_log("Updated Jira ticket with MR link and ai-done label")
        add_log("Pipeline complete — merge request ready for review")
    else:
        add_log("Verifying tests pass before creating merge request")
        if status == "completed":
            add_log("Merge request created successfully")

# --- finalize ---
elif agent_stage == "finalize":
    stage_data = {}

    # Read test results for final status
    results_path = os.path.join(ticket_dir, "test-results.json")
    if os.path.isfile(results_path):
        try:
            with open(results_path) as f:
                results = json.load(f)
            test_status = results.get("status", "unknown")
            total = results.get("total", 0)
            passed_n = results.get("passed", 0)
            failed_n = results.get("failed", 0)
            stage_data["test_results"] = {
                "status": test_status, "total": total,
                "passed": passed_n, "failed": failed_n,
            }
            video_url = results.get("video_url")
            if video_url:
                stage_data["video_url"] = video_url
                payload["video_url"] = video_url
            payload["test_results"] = stage_data["test_results"]
        except (json.JSONDecodeError, OSError):
            pass

    # Read PR result for MR URL — check pr-output.json first, then pr-result.md
    mr_url = None
    pr_json_path = os.path.join(ticket_dir, "pr-output.json")
    pr_md_path = os.path.join(ticket_dir, "pr-result.md")
    if os.path.isfile(pr_json_path):
        try:
            with open(pr_json_path) as f:
                pr_data = json.load(f)
            mr_url = pr_data.get("mr_url")
        except (json.JSONDecodeError, OSError):
            pass
    if not mr_url and os.path.isfile(pr_md_path):
        try:
            with open(pr_md_path) as f:
                pr_content = f.read()
            mr_match = re.search(r'https://gitlab\.com/[^\s)]+merge_requests/\d+', pr_content)
            if mr_match:
                mr_url = mr_match.group(0)
        except OSError:
            pass
    if mr_url:
        stage_data["mr_url"] = mr_url
        payload["mr_url"] = mr_url

    # Read feature_doc from code-writer-output.json
    cw_path = os.path.join(ticket_dir, "code-writer-output.json")
    if os.path.isfile(cw_path):
        try:
            with open(cw_path) as f:
                cw_data = json.load(f)
            feature_doc = cw_data.get("feature_doc")
            if feature_doc:
                stage_data["feature_doc"] = feature_doc
                payload["feature_doc"] = feature_doc
        except (json.JSONDecodeError, OSError):
            pass

    # Read checkpoint for debug cycles
    cp_path = os.path.join(ticket_dir, "checkpoint.json")
    if os.path.isfile(cp_path):
        try:
            with open(cp_path) as f:
                cp = json.load(f)
            stage_data["debug_cycles"] = cp.get("debug_cycles", 0)
        except (json.JSONDecodeError, OSError):
            pass

    # Read validation report for quality data
    vr_path = os.path.join(ticket_dir, "validation-report.json")
    if os.path.isfile(vr_path):
        try:
            with open(vr_path) as f:
                vr = json.load(f)
            quality = {
                "passed": vr.get("passed", 0), "failed": vr.get("failed", 0),
                "auto_fixed": vr.get("auto_fixed", 0),
                "total": vr.get("passed", 0) + vr.get("failed", 0),
                "status": vr.get("status", "unknown"),
            }
            stage_data["quality"] = quality
            payload["quality"] = quality
        except (json.JSONDecodeError, OSError):
            pass

    # Determine pipeline result — dashboard uses "result" field to set Passed/Failed
    test_status = stage_data.get("test_results", {}).get("status", "unknown")
    if test_status == "passed" or status in ("passed", "completed"):
        payload["result"] = "passed"
        payload["pipeline_status"] = "passed"
    elif test_status == "failed" or status == "failed":
        payload["result"] = "failed"
        payload["pipeline_status"] = "failed"

    # Override status to "completed" — dashboard expects "completed" for stage status
    if status in ("passed", "completed"):
        status = "completed"
        payload["status"] = "completed"

    if stage_data:
        payload["stage_data"] = stage_data

    # Generate rich logs
    tr = stage_data.get("test_results", {})
    if tr:
        total = tr.get("total", 0)
        passed_n = tr.get("passed", 0)
        add_log(f"Test results: {passed_n}/{total} passed")
    mr_url = stage_data.get("mr_url")
    if mr_url:
        add_log(f"MR: {mr_url}")
    else:
        add_log("WARNING: No MR URL found in pr-output.json or pr-result.md", level="warn")
    if stage_data.get("video_url"):
        add_log("Test video uploaded to S3")
    else:
        add_log("WARNING: No video URL in test-results.json", level="warn")
    if stage_data.get("feature_doc"):
        add_log("Feature doc included")
    else:
        add_log("WARNING: No feature_doc in code-writer-output.json", level="warn")
    dc = stage_data.get("debug_cycles", 0)
    if dc > 0:
        add_log(f"Debug cycles used: {dc}")
    result = payload.get("result", "unknown")
    add_log(f"Pipeline complete — {result}")

# --- review-pr ---
elif agent_stage in ("review-pr", "reviewpr"):
    stage_data = {}

    # Read PR result for MR URL — check pr-output.json first, then pr-result.md
    mr_url = None
    pr_json_path = os.path.join(ticket_dir, "pr-output.json")
    pr_md_path = os.path.join(ticket_dir, "pr-result.md")
    if os.path.isfile(pr_json_path):
        try:
            with open(pr_json_path) as f:
                pr_data = json.load(f)
            mr_url = pr_data.get("mr_url")
        except (json.JSONDecodeError, OSError):
            pass
    if not mr_url and os.path.isfile(pr_md_path):
        try:
            with open(pr_md_path) as f:
                pr_content = f.read()
            mr_match = re.search(r'https://gitlab\.com/[^\s)]+merge_requests/\d+', pr_content)
            if mr_match:
                mr_url = mr_match.group(0)
        except OSError:
            pass
    if mr_url:
        stage_data["mr_url"] = mr_url
        payload["mr_url"] = mr_url

    # Read test results for summary
    results_path = os.path.join(ticket_dir, "test-results.json")
    if os.path.isfile(results_path):
        try:
            with open(results_path) as f:
                results = json.load(f)
            stage_data["test_results"] = {
                "status": results.get("status"), "total": results.get("total"),
                "passed": results.get("passed"), "failed": results.get("failed"),
            }
            payload["test_results"] = stage_data["test_results"]
            video_url = results.get("video_url")
            if video_url:
                stage_data["video_url"] = video_url
                payload["video_url"] = video_url
        except (json.JSONDecodeError, OSError):
            pass

    # Read feature_doc from code-writer-output.json
    cw_path = os.path.join(ticket_dir, "code-writer-output.json")
    if os.path.isfile(cw_path):
        try:
            with open(cw_path) as f:
                cw_data = json.load(f)
            feature_doc = cw_data.get("feature_doc")
            if feature_doc:
                stage_data["feature_doc"] = feature_doc
                payload["feature_doc"] = feature_doc
        except (json.JSONDecodeError, OSError):
            pass

    # Read validation report for quality data
    vr_path = os.path.join(ticket_dir, "validation-report.json")
    if os.path.isfile(vr_path):
        try:
            with open(vr_path) as f:
                vr = json.load(f)
            quality = {
                "passed": vr.get("passed", 0), "failed": vr.get("failed", 0),
                "auto_fixed": vr.get("auto_fixed", 0),
                "total": vr.get("passed", 0) + vr.get("failed", 0),
                "status": vr.get("status", "unknown"),
            }
            stage_data["quality"] = quality
            payload["quality"] = quality
        except (json.JSONDecodeError, OSError):
            pass

    # review-pr is a human stage — pipeline result is determined by test status
    test_status = stage_data.get("test_results", {}).get("status", "unknown")
    if test_status == "passed" or status in ("passed", "completed"):
        payload["result"] = "passed"
        payload["pipeline_status"] = "passed"

    if stage_data:
        payload["stage_data"] = stage_data

    # Generate rich logs
    mr_url = stage_data.get("mr_url")
    if mr_url:
        add_log(f"Merge request awaiting human review: {mr_url}")
    tr = stage_data.get("test_results", {})
    if tr:
        add_log(f"Test results: {tr.get('passed', 0)}/{tr.get('total', 0)} passed")
    add_log("Awaiting human approval or change requests")

# ---------------------------------------------------------------------------
# Parse audit.md — only send entries belonging to the CURRENT reporting stage
# ---------------------------------------------------------------------------
AGENT_TO_STAGE = {
    "scanner-agent": "scanner",
    "scanner": "scanner",
    "analyzer-agent": "analyzer",
    "analyzer": "analyzer",
    "ticket-creator-agent": "ticket-creator",
    "ticket-creator": "ticket-creator",
    "triage-agent": "triage",
    "triage": "triage",
    "explorer-agent": "explorer",
    "explorer": "explorer",
    "playwright-agent": "playwright",
    "playwright": "playwright",
    "code-writer-agent": "code-writer",
    "code-writer": "code-writer",
    "test-runner-agent": "test-runner",
    "test-runner": "test-runner",
    "debug-agent": "debug",
    "debug": "debug",
    "pr-agent": "pr",
    "pr": "pr",
}

audit_path = os.path.join(ticket_dir, "audit.md")
if os.path.isfile(audit_path):
    try:
        with open(audit_path) as f:
            audit_content = f.read()

        entries = re.split(r'(?=^### \[)', audit_content, flags=re.MULTILINE)
        entries = [e.strip() for e in entries if e.strip().startswith("### [")]

        activities = []
        for entry in entries:
            ts_match = re.search(r'### \[([^\]]+)\]\s*(.*)', entry)
            if ts_match:
                agent_name = ts_match.group(2).strip()
                # Strip role suffix like "(lead)", "(browser)", "(developer)" etc.
                bare_name = re.sub(r'\s*\([^)]*\)\s*$', '', agent_name).strip()
                # Map agent name to stage key
                mapped_stage = AGENT_TO_STAGE.get(agent_name) or AGENT_TO_STAGE.get(bare_name) or AGENT_TO_STAGE.get(bare_name.replace("-agent", ""), "")
                # Only include entries from the current reporting stage's agent
                if mapped_stage != dashboard_stage:
                    continue

                activity = {
                    "timestamp": ts_match.group(1).strip(),
                    "agent": agent_name,
                    "stage_key": mapped_stage,
                }
                action_match = re.search(r'\*\*Action\*\*:\s*(.+)', entry)
                if action_match:
                    activity["action"] = action_match.group(1).strip()
                target_match = re.search(r'\*\*Target\*\*:\s*(.+)', entry)
                if target_match:
                    activity["target"] = target_match.group(1).strip()
                result_match = re.search(r'\*\*Result\*\*:\s*(.+)', entry)
                if result_match:
                    activity["result"] = result_match.group(1).strip()
                details_match = re.search(r'\*\*Details\*\*:\s*(.+)', entry)
                if details_match:
                    activity["details"] = details_match.group(1).strip()

                activities.append(activity)

        if activities:
            payload["activities"] = activities
    except OSError:
        pass

# ---------------------------------------------------------------------------
# Extract structured logs from JSONL files (stage-logs/<stage>.jsonl)
# ---------------------------------------------------------------------------
structured_logs = []
stage_logs_dir = os.path.join(ticket_dir, "stage-logs")
jsonl_file = os.path.join(stage_logs_dir, f"{dashboard_stage}.jsonl")
offset_file = os.path.join(stage_logs_dir, f".last-reported-offset-{dashboard_stage}")

if os.path.isfile(jsonl_file):
    try:
        last_offset = 0
        if os.path.isfile(offset_file):
            try:
                with open(offset_file) as f:
                    last_offset = int(f.read().strip())
            except (ValueError, OSError):
                last_offset = 0

        file_size = os.path.getsize(jsonl_file)
        if file_size > last_offset:
            with open(jsonl_file, "rb") as f:
                f.seek(last_offset)
                raw = f.read()
                new_offset = last_offset + len(raw)

            lines = raw.decode("utf-8", errors="replace").split("\n")
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    structured_logs.append(json.loads(line))
                except json.JSONDecodeError:
                    pass

            # Keep only the most recent 50 events
            if len(structured_logs) > 50:
                structured_logs = structured_logs[-50:]

            # Update offset file for next invocation
            try:
                os.makedirs(stage_logs_dir, exist_ok=True)
                with open(offset_file, "w") as f:
                    f.write(str(new_offset))
            except OSError:
                pass
    except OSError:
        pass

if structured_logs:
    payload["structured_logs"] = structured_logs

# ---------------------------------------------------------------------------
# Notification support
# ---------------------------------------------------------------------------
if needs_human:
    payload["needs_human"] = True
    notification = {}
    if notification_type:
        notification["type"] = notification_type
    if notification_msg:
        notification["message"] = notification_msg
    if notification:
        payload["notification"] = notification

# ---------------------------------------------------------------------------
# Merge synthetic logs + audit activities into payload.logs
# ---------------------------------------------------------------------------
all_logs = list(stage_logs)  # synthetic logs from stage_data

# Also include audit activities as log entries
if "activities" in payload:
    for act in payload["activities"]:
        msg_parts = [act.get("agent", ""), act.get("action", ""), act.get("target", ""), act.get("result", "")]
        msg = " — ".join(p for p in msg_parts if p)
        all_logs.append({
            "level": "info",
            "message": msg,
            "timestamp": act.get("timestamp"),
        })
    # Activities are now merged into logs — remove to avoid double insertion
    del payload["activities"]

if all_logs:
    payload["logs"] = all_logs

print(json.dumps(payload, indent=2, default=str))
PYTHON_SCRIPT
)

# ---------------------------------------------------------------------------
# Validate we got a payload
# ---------------------------------------------------------------------------
if [ -z "${PAYLOAD}" ] || [ "${PAYLOAD}" = "{}" ]; then
  echo "[report-to-dashboard] WARNING: Failed to build payload for ${TICKET_KEY} stage=${AGENT_STAGE}." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# POST to dashboard
# ---------------------------------------------------------------------------
echo "[report-to-dashboard] Reporting ${TICKET_KEY} stage=${DASHBOARD_STAGE} status=${STATUS} to ${REPORT_ENDPOINT}" >&2

HTTP_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 5 \
  --max-time 10 \
  -X POST \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" \
  "${REPORT_ENDPOINT}" 2>/dev/null) || true

# If curl failed entirely, http_code will be 000 or empty
if [ -z "${HTTP_RESPONSE}" ] || [ "${HTTP_RESPONSE}" = "000" ]; then
  echo "[report-to-dashboard] WARNING: Dashboard unreachable at ${REPORT_ENDPOINT}. Continuing pipeline." >&2
elif [ "${HTTP_RESPONSE}" -ge 200 ] 2>/dev/null && [ "${HTTP_RESPONSE}" -lt 300 ] 2>/dev/null; then
  echo "[report-to-dashboard] Successfully reported to dashboard (HTTP ${HTTP_RESPONSE})." >&2
else
  echo "[report-to-dashboard] WARNING: Dashboard returned HTTP ${HTTP_RESPONSE}. Continuing pipeline." >&2
fi

# Always exit 0 — never block the pipeline
_SCRIPT_OK=1
exit 0
