#!/usr/bin/env bash
# watch-check.sh — Check if a Jira ticket has changed since triage.
# Compares stored ticket_hash from triage.json against current ticket state.
# Used by the --watch flag in the qa-autonomous-e2e pipeline.
#
# Usage: watch-check.sh <ticket-key>
#
# Outputs a JSON result to stdout:
#   { "changed": true/false, "change_type": "...", "status_closed": true/false, "details": "...", "new_hash": "..." }
#
# Security: Ticket key is validated against a strict pattern. Never blocks the pipeline.

set -euo pipefail

# Ensure the script never fails the pipeline — trap errors and always exit 0
_SCRIPT_OK=0
trap 'if [ "$_SCRIPT_OK" -eq 0 ]; then echo "{\"changed\":false,\"change_type\":\"none\",\"status_closed\":false,\"details\":\"Watch check encountered an error\",\"new_hash\":\"\"}" ; fi; exit 0' ERR EXIT

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [ $# -lt 1 ]; then
  echo '{"changed":false,"change_type":"none","status_closed":false,"details":"No ticket key provided","new_hash":""}'
  _SCRIPT_OK=1
  exit 0
fi

TICKET_KEY="$1"

# QA Agent Security: Validate ticket key format to prevent path traversal
if ! echo "${TICKET_KEY}" | grep -qE '^[A-Z]{1,10}-[0-9]{1,6}$'; then
  echo '{"changed":false,"change_type":"none","status_closed":false,"details":"Invalid ticket key format","new_hash":""}'
  _SCRIPT_OK=1
  exit 0
fi

# ---------------------------------------------------------------------------
# Read stored triage data
# ---------------------------------------------------------------------------
TICKET_DIR="${PROJECT_ROOT}/memory/tickets/${TICKET_KEY}"
TRIAGE_FILE="${TICKET_DIR}/triage.json"

if [ ! -f "${TRIAGE_FILE}" ]; then
  echo '{"changed":false,"change_type":"none","status_closed":false,"details":"No triage.json found — cannot compare","new_hash":""}'
  _SCRIPT_OK=1
  exit 0
fi

# ---------------------------------------------------------------------------
# Fetch current ticket data from Jira
# ---------------------------------------------------------------------------
JIRA_OUTPUT=$(acli jira workitem view "${TICKET_KEY}" --fields "summary,description,status,priority" 2>/dev/null) || JIRA_OUTPUT=""

if [ -z "${JIRA_OUTPUT}" ]; then
  echo '{"changed":false,"change_type":"none","status_closed":false,"details":"Failed to fetch Jira ticket","new_hash":""}'
  _SCRIPT_OK=1
  exit 0
fi

# ---------------------------------------------------------------------------
# Compare using python3
# ---------------------------------------------------------------------------
RESULT=$(
  TRIAGE_FILE="${TRIAGE_FILE}" \
  JIRA_OUTPUT="${JIRA_OUTPUT}" \
  python3 << 'PYTHON_SCRIPT' 2>/dev/null || echo '{"changed":false,"change_type":"none","status_closed":false,"details":"Python comparison failed","new_hash":""}'
import json
import hashlib
import os
import re
import sys

triage_file = os.environ.get("TRIAGE_FILE", "")
jira_output = os.environ.get("JIRA_OUTPUT", "")

# Read stored triage data
try:
    with open(triage_file) as f:
        triage = json.load(f)
except Exception:
    print(json.dumps({
        "changed": False,
        "change_type": "none",
        "status_closed": False,
        "details": "Could not read triage.json",
        "new_hash": ""
    }))
    sys.exit(0)

stored_hash = triage.get("ticket_hash", "")

# ---------------------------------------------------------------------------
# Hash integrity check: verify stored hash matches triage.json content.
# If the hash was computed from different content (race condition, stale data),
# recompute it from what's actually in triage.json — that's the baseline the
# pipeline acted on.
# ---------------------------------------------------------------------------
stored_desc = triage.get("description", "")
stored_summary = triage.get("summary", "")
recomputed_hash = hashlib.md5((stored_desc + stored_summary).encode("utf-8")).hexdigest()

if stored_hash and recomputed_hash != stored_hash:
    # Hash is stale / out of sync — use recomputed hash as the real baseline
    stored_hash = recomputed_hash

# Parse Jira output to extract fields
# acli output is typically key-value lines like "Summary: ...", "Description: ...", etc.
current_summary = ""
current_description = ""
current_status = ""
current_priority = ""

lines = jira_output.split("\n")
current_field = None
current_value_lines = []

for line in lines:
    # Check for field headers (acli uses "Field: value" format)
    field_match = re.match(r'^(Summary|Description|Status|Priority)\s*:\s*(.*)', line, re.IGNORECASE)
    if field_match:
        # Save previous field
        if current_field:
            value = "\n".join(current_value_lines).strip()
            if current_field == "summary":
                current_summary = value
            elif current_field == "description":
                current_description = value
            elif current_field == "status":
                current_status = value
            elif current_field == "priority":
                current_priority = value

        current_field = field_match.group(1).lower()
        current_value_lines = [field_match.group(2).strip()]
    elif current_field:
        current_value_lines.append(line)

# Save the last field
if current_field:
    value = "\n".join(current_value_lines).strip()
    if current_field == "summary":
        current_summary = value
    elif current_field == "description":
        current_description = value
    elif current_field == "status":
        current_status = value
    elif current_field == "priority":
        current_priority = value

# Compute hash of current description + summary
hash_input = (current_description + current_summary).encode("utf-8")
new_hash = hashlib.md5(hash_input).hexdigest()

# Check if ticket is closed/cancelled
closed_statuses = ["done", "closed", "cancelled", "canceled", "resolved", "won't do", "rejected"]
status_closed = current_status.lower().strip() in closed_statuses

# Compare hashes
if not stored_hash:
    # No stored hash — treat as no change (backward compatibility)
    result = {
        "changed": False,
        "change_type": "none",
        "status_closed": status_closed,
        "details": "No stored hash in triage.json — skipping comparison",
        "new_hash": new_hash
    }
elif status_closed:
    result = {
        "changed": True,
        "change_type": "status",
        "status_closed": True,
        "details": f"Ticket status is '{current_status}' — ticket closed/cancelled",
        "new_hash": new_hash
    }
elif new_hash != stored_hash:
    # Hash changed — determine what changed
    stored_summary = triage.get("summary", "")
    stored_priority = triage.get("priority", "")

    # Check if priority changed
    if current_priority.lower().strip() != stored_priority.lower().strip() and new_hash == stored_hash:
        change_type = "priority"
        details = f"Priority changed from '{stored_priority}' to '{current_priority}'"
    else:
        # Description or summary changed — check which
        # Recompute hash with just the stored summary to see if description changed
        change_type = "description"
        details = "Description or summary was edited since triage"

        # Try to narrow it down
        if current_summary.strip() != stored_summary.strip():
            change_type = "summary"
            details = f"Summary changed from '{stored_summary[:80]}' to '{current_summary[:80]}'"

            # Check if description also changed by comparing hash without summary change
            summary_only_hash = hashlib.md5((current_description + stored_summary).encode("utf-8")).hexdigest()
            if summary_only_hash != stored_hash:
                change_type = "description"
                details = "Both description and summary were edited since triage"
        else:
            change_type = "description"
            details = "Description was edited since triage"

    result = {
        "changed": True,
        "change_type": change_type,
        "status_closed": False,
        "details": details,
        "new_hash": new_hash
    }
else:
    # Check priority separately (not part of hash)
    stored_priority = triage.get("priority", "")
    if current_priority and stored_priority and current_priority.lower().strip() != stored_priority.lower().strip():
        result = {
            "changed": True,
            "change_type": "priority",
            "status_closed": False,
            "details": f"Priority changed from '{stored_priority}' to '{current_priority}'",
            "new_hash": new_hash
        }
    else:
        result = {
            "changed": False,
            "change_type": "none",
            "status_closed": False,
            "details": "No changes detected",
            "new_hash": new_hash
        }

print(json.dumps(result))
PYTHON_SCRIPT
)

echo "${RESULT}"

# Always exit 0 — never block the pipeline
_SCRIPT_OK=1
exit 0
