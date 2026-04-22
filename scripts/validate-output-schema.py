#!/usr/bin/env python3
"""Validates pipeline output files against per-stage schemas and checkpoint integrity.

Usage:
    python3 scripts/validate-output-schema.py <ticket-key> <stage>
    python3 scripts/validate-output-schema.py OXDEV-123 triage
    python3 scripts/validate-output-schema.py OXDEV-123 checkpoint  # validate checkpoint only

Returns JSON: {"valid": true/false, "errors": [...], "warnings": [...]}
"""

import json
import os
import sys
from datetime import datetime

# ---------------------------------------------------------------------------
# Stage schemas: field -> (required: bool, type_check: callable, description)
# ---------------------------------------------------------------------------

VALID_STAGES = ["triage", "explorer", "playwright", "code-writer", "test-runner", "debug", "cross-env-check", "pr"]

STAGE_SCHEMAS = {
    "triage": {
        "file": "triage.json",
        "required_fields": {
            "ticket_key": (True, lambda v: isinstance(v, str) and v.startswith("OXDEV-"), "must be OXDEV-NNN"),
            "feature_area": (True, lambda v: isinstance(v, str) and len(v) > 0, "must be non-empty string"),
            "test_type": (True, lambda v: v in ("UI", "API", "mixed", "ui", "api"), "must be UI, API, or mixed"),
            "complexity": (True, lambda v: v in ("S", "M", "L"), "must be S, M, or L"),
        },
    },
    "explorer": {
        "file": "explorer-output.json",
        "required_fields": {
            "similar_tests": (True, lambda v: isinstance(v, list), "must be an array"),
            "reusable_actions": (True, lambda v: isinstance(v, list), "must be an array"),
        },
    },
    "playwright": {
        "file": "playwright-data.json",
        "required_fields": {
            "selectors": (True, lambda v: isinstance(v, dict), "must be an object"),
            "navigation_flow": (True, lambda v: isinstance(v, list), "must be an array"),
        },
        "warnings": {
            "selectors": lambda v: "selectors object is empty" if isinstance(v, dict) and len(v) == 0 else None,
        },
    },
    "code-writer": {
        "file": "code-writer-output.json",
        "required_fields": {
            "test_file": (True, lambda v: isinstance(v, str) and len(v) > 0, "must be non-empty string"),
            "files": (True, lambda v: isinstance(v, list), "must be an array"),
            "branch_name": (True, lambda v: isinstance(v, str) and len(v) > 0, "must be non-empty string"),
        },
        "warnings": {
            "files": lambda v: next(
                (f"file entry missing diff with @@ markers: {f.get('path', '?')}"
                 for f in (v if isinstance(v, list) else [])
                 if isinstance(f, dict) and "diff" in f and "@@" not in str(f["diff"])),
                None
            ),
        },
    },
    "test-runner": {
        "file": "test-results.json",
        "required_fields": {
            "status": (True, lambda v: v in ("passed", "failed", "unknown"), "must be passed, failed, or unknown"),
            "total": (True, lambda v: isinstance(v, int) and v >= 0, "must be a non-negative integer"),
            "passed": (True, lambda v: isinstance(v, int) and v >= 0, "must be a non-negative integer"),
            "failed": (True, lambda v: isinstance(v, int) and v >= 0, "must be a non-negative integer"),
        },
        "conditional": {
            "failures": lambda data: (
                isinstance(data.get("failures"), list)
                if data.get("status") == "failed"
                else True
            ),
            "failures_msg": "when status=failed, failures must be an array",
        },
    },
    "debug": {
        "file": "debug-output.json",
        "required_fields": {
            "total_cycles": (True, lambda v: isinstance(v, int) and 0 <= v <= 3, "must be integer 0-3"),
            "final_status": (True, lambda v: isinstance(v, str) and len(v) > 0, "must be non-empty string"),
            "cycles": (True, lambda v: isinstance(v, list), "must be an array"),
        },
        "warnings": {
            "cycles": lambda v: next(
                (f"cycle {i+1} missing cycle_number or outcome"
                 for i, c in enumerate(v if isinstance(v, list) else [])
                 if not isinstance(c, dict) or "cycle_number" not in c or "outcome" not in c),
                None
            ),
        },
    },
    "cross-env-check": {
        "file": "cross-env-results.json",
        "required_fields": {
            "envs": (True, lambda v: isinstance(v, dict) and len(v) > 0, "must be non-empty dict"),
            "required_envs": (True, lambda v: isinstance(v, list), "must be an array"),
            "optional_envs": (True, lambda v: isinstance(v, list), "must be an array"),
            "required_passed": (True, lambda v: isinstance(v, bool), "must be boolean"),
        },
    },
    "pr": {
        "file": "pr-output.json",
        "required_fields": {
            "mr_url": (True, lambda v: isinstance(v, str) and len(v) > 0, "must be non-empty string"),
            "branch_name": (True, lambda v: isinstance(v, str) and len(v) > 0, "must be non-empty string"),
            "target_branch": (True, lambda v: v == "developmentV2", "must be developmentV2"),
        },
    },
}


def validate_checkpoint(memory_dir):
    """Validate checkpoint.json integrity."""
    errors = []
    warnings = []
    cp_path = os.path.join(memory_dir, "checkpoint.json")

    if not os.path.isfile(cp_path):
        return errors, warnings  # No checkpoint yet is fine

    try:
        with open(cp_path) as f:
            cp = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        errors.append(f"checkpoint.json: invalid JSON: {e}")
        return errors, warnings

    # completed_stages must be a subset of known stages
    completed = cp.get("completed_stages", [])
    if not isinstance(completed, list):
        errors.append("checkpoint.json: completed_stages must be an array")
    else:
        unknown = [s for s in completed if s not in VALID_STAGES]
        if unknown:
            warnings.append(f"checkpoint.json: unknown stages in completed_stages: {unknown}")

    # debug_cycles must be 0-3
    dc = cp.get("debug_cycles", 0)
    if not isinstance(dc, int) or dc < 0 or dc > 3:
        errors.append(f"checkpoint.json: debug_cycles must be 0-3, got {dc}")

    # last_updated should be valid ISO-8601
    lu = cp.get("last_updated", "")
    if lu:
        try:
            datetime.fromisoformat(lu.replace("Z", "+00:00"))
        except (ValueError, AttributeError):
            warnings.append(f"checkpoint.json: last_updated is not valid ISO-8601: {lu}")

    # stage_outputs paths should exist
    outputs = cp.get("stage_outputs", {})
    if isinstance(outputs, dict):
        for stage, path in outputs.items():
            if not os.path.isfile(path):
                warnings.append(f"checkpoint.json: stage_outputs.{stage} file not found: {path}")
            elif os.path.getsize(path) == 0:
                warnings.append(f"checkpoint.json: stage_outputs.{stage} file is empty: {path}")

    return errors, warnings


def validate_stage(memory_dir, stage):
    """Validate a specific stage's output file against its schema."""
    errors = []
    warnings = []

    schema = STAGE_SCHEMAS.get(stage)
    if not schema:
        # Unknown stage, skip (don't error — might be a new stage)
        return errors, warnings

    file_path = os.path.join(memory_dir, schema["file"])

    if not os.path.isfile(file_path):
        errors.append(f"{schema['file']}: file not found")
        return errors, warnings

    if os.path.getsize(file_path) == 0:
        errors.append(f"{schema['file']}: file is empty")
        return errors, warnings

    try:
        with open(file_path) as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        errors.append(f"{schema['file']}: invalid JSON: {e}")
        return errors, warnings

    # Check required fields
    for field, (required, check, desc) in schema.get("required_fields", {}).items():
        if field not in data:
            if required:
                errors.append(f"{schema['file']}: missing required field '{field}'")
        else:
            if not check(data[field]):
                errors.append(f"{schema['file']}: field '{field}' {desc}, got: {repr(data[field])[:80]}")

    # Check conditional rules
    conditional = schema.get("conditional", {})
    for key, check_fn in conditional.items():
        if key.endswith("_msg"):
            continue
        if not check_fn(data):
            msg_key = f"{key}_msg"
            errors.append(f"{schema['file']}: {conditional.get(msg_key, f'conditional check failed for {key}')}")

    # Check warnings
    for field, warn_fn in schema.get("warnings", {}).items():
        if field in data:
            warn = warn_fn(data[field])
            if warn:
                warnings.append(f"{schema['file']}: {warn}")

    return errors, warnings


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"valid": False, "errors": ["Usage: validate-output-schema.py <ticket-key> <stage>"], "warnings": []}))
        sys.exit(1)

    ticket_key = sys.argv[1]
    stage = sys.argv[2]
    memory_dir = os.path.join("memory", "tickets", ticket_key)

    all_errors = []
    all_warnings = []

    # Always validate checkpoint
    cp_errors, cp_warnings = validate_checkpoint(memory_dir)
    all_errors.extend(cp_errors)
    all_warnings.extend(cp_warnings)

    # Validate stage output if not just "checkpoint"
    if stage != "checkpoint":
        s_errors, s_warnings = validate_stage(memory_dir, stage)
        all_errors.extend(s_errors)
        all_warnings.extend(s_warnings)

    result = {
        "valid": len(all_errors) == 0,
        "errors": all_errors,
        "warnings": all_warnings,
    }

    print(json.dumps(result))
    sys.exit(0 if result["valid"] else 1)


if __name__ == "__main__":
    main()
