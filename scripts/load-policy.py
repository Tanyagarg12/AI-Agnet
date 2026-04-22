#!/usr/bin/env python3
"""Loads and merges agent permission policies from .claude/policies/.

Usage:
    python3 scripts/load-policy.py <agent-name>                    # full merged policy as JSON
    python3 scripts/load-policy.py <agent-name> --field <path>     # specific field (dot-separated)
    python3 scripts/load-policy.py _common --field filesystem.never_modify

Examples:
    python3 scripts/load-policy.py playwright-agent
    python3 scripts/load-policy.py _common --field filesystem.never_modify
    python3 scripts/load-policy.py code-writer-agent --field required_outputs
"""

import json
import os
import sys


POLICY_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".claude", "policies")


def load_json_policy(name):
    """Load a JSON policy file by agent name."""
    path = os.path.join(POLICY_DIR, f"{name}.json")
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        return json.load(f)


def deep_merge(base, override):
    """Deep merge override into base. Override values take precedence.
    Lists are replaced (not appended). Dicts are recursively merged.
    """
    result = dict(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def get_nested(data, field_path):
    """Get a nested field by dot-separated path."""
    parts = field_path.split(".")
    current = data
    for part in parts:
        if isinstance(current, dict) and part in current:
            current = current[part]
        else:
            return None
    return current


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: load-policy.py <agent-name> [--field <path>]"}))
        sys.exit(1)

    agent_name = sys.argv[1]
    field_path = None

    # Parse --field argument
    if "--field" in sys.argv:
        idx = sys.argv.index("--field")
        if idx + 1 < len(sys.argv):
            field_path = sys.argv[idx + 1]
        else:
            print(json.dumps({"error": "--field requires a value"}))
            sys.exit(1)

    # Load common policy
    common = load_json_policy("_common")
    if common is None:
        common = {}

    # If requesting _common itself, just return it
    if agent_name == "_common":
        merged = common
    else:
        # Load agent-specific policy
        agent_policy = load_json_policy(agent_name)
        if agent_policy is None:
            print(json.dumps({"error": f"Policy not found: {agent_name}"}))
            sys.exit(1)

        # Deep merge: agent overrides common
        merged = deep_merge(common, agent_policy)

    # Extract specific field if requested
    if field_path:
        value = get_nested(merged, field_path)
        if value is None:
            print(json.dumps(None))
        else:
            print(json.dumps(value))
    else:
        print(json.dumps(merged, indent=2))


if __name__ == "__main__":
    main()
