#!/usr/bin/env python3
"""Cross-reference action file selector references against actual selector JSON.

Ensures action files only reference selectors that exist in the JSON file.
Used by the code-writer atomic write loop to verify actions before committing.

Usage:
    python3 scripts/verify-action-selectors.py <actions-file> <selectors-json>

Output: JSON to stdout
    {"valid": true, "missing": [], "referenced": ["key1", "key2"], "available": ["key1", "key2", "key3"]}
"""

import json
import re
import sys
import os


def extract_selector_references(actions_content):
    """Extract selector key references from an action JS file.

    Looks for patterns like:
        selectors.keyName
        selectors["keyName"]
        selectors['keyName']
    """
    refs = set()

    # Dot notation: selectors.keyName
    refs.update(re.findall(r"selectors\.(\w+)", actions_content))

    # Bracket notation: selectors["keyName"] or selectors['keyName']
    refs.update(re.findall(r'selectors\[\s*["\'](\w+)["\']\s*\]', actions_content))

    return sorted(refs)


def main():
    if len(sys.argv) < 3:
        print(
            "Usage: python3 scripts/verify-action-selectors.py <actions-file> <selectors-json>",
            file=sys.stderr,
        )
        sys.exit(1)

    actions_file = sys.argv[1]
    selectors_file = sys.argv[2]

    if not os.path.exists(actions_file):
        print(json.dumps({"valid": False, "error": f"Actions file not found: {actions_file}"}))
        sys.exit(1)

    if not os.path.exists(selectors_file):
        print(json.dumps({"valid": False, "error": f"Selectors file not found: {selectors_file}"}))
        sys.exit(1)

    with open(actions_file, "r") as f:
        actions_content = f.read()

    try:
        with open(selectors_file, "r") as f:
            selectors_data = json.load(f)
    except json.JSONDecodeError as e:
        print(json.dumps({"valid": False, "error": f"Invalid JSON in selectors file: {e}"}))
        sys.exit(1)

    available_keys = set(selectors_data.keys())
    referenced_keys = extract_selector_references(actions_content)
    missing = [k for k in referenced_keys if k not in available_keys]

    result = {
        "valid": len(missing) == 0,
        "missing": missing,
        "referenced": referenced_keys,
        "available": sorted(available_keys),
    }

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
