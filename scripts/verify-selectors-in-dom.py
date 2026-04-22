#!/usr/bin/env python3
"""Compare selectors JSON against a playwright-cli snapshot to verify DOM matches.

Used by the code-writer atomic write loop to quickly check if selectors
match elements in the live page before committing.

Usage:
    python3 scripts/verify-selectors-in-dom.py <selectors-json> --snapshot <snapshot-file>

Output: JSON to stdout
    {"total": 12, "found": 10, "not_found": ["key1", "key2"], "pass_rate": 0.83}

The snapshot file should be the text output of `playwright-cli snapshot` or
`$CDP snap <target>`, which contains accessibility tree lines like:
    - button "Submit" [ref=e42] [data-testid="submit-btn"]
"""

import json
import re
import sys
import os
import argparse


def extract_testids_from_snapshot(snapshot_content):
    """Extract all data-testid values from a playwright snapshot."""
    testids = set()
    # Match [data-testid="value"] patterns
    for match in re.findall(r'\[data-testid="([^"]+)"\]', snapshot_content):
        testids.add(match)
    return testids


def extract_text_from_snapshot(snapshot_content):
    """Extract visible text content from snapshot."""
    texts = set()
    # Match quoted text in snapshot like: heading "Reports" or button "Filter"
    for match in re.findall(r'"([^"]+)"', snapshot_content):
        texts.add(match.lower())
    return texts


def extract_roles_from_snapshot(snapshot_content):
    """Extract element roles from snapshot."""
    roles = set()
    # Match role names like: - button, - heading, - link, - navigation
    for match in re.findall(r"-\s+(\w+)\s+", snapshot_content):
        roles.add(match.lower())
    return roles


def check_selector_in_snapshot(selector_value, testids, texts, roles):
    """Check if a selector would likely match something in the snapshot.

    Handles pipe-separated fallbacks: tries primary first, then fallbacks.
    """
    alternatives = [s.strip() for s in selector_value.split("|")]

    for alt in alternatives:
        # Check data-testid match
        testid_match = re.search(r"@data-testid=['\"]([^'\"]+)['\"]", alt)
        if testid_match and testid_match.group(1) in testids:
            return True

        # Check data-cy match
        cy_match = re.search(r"@data-cy=['\"]([^'\"]+)['\"]", alt)
        if cy_match and cy_match.group(1) in testids:
            return True

        # Check text content match
        text_match = re.search(r"contains\s*\(\s*(?:text\(\)|\.)\s*,\s*['\"]([^'\"]+)['\"]\s*\)", alt)
        if text_match and text_match.group(1).lower() in texts:
            return True

        # Check contains(@class,...) — can't verify from snapshot easily, skip
        # Check structural XPath — can't verify from snapshot easily, skip

    return False


def main():
    parser = argparse.ArgumentParser(
        description="Verify selectors against a DOM snapshot"
    )
    parser.add_argument("selectors_json", help="Path to selectors JSON file")
    parser.add_argument(
        "--snapshot", required=True, help="Path to playwright snapshot text file"
    )

    args = parser.parse_args()

    if not os.path.exists(args.selectors_json):
        print(json.dumps({"error": f"Selectors file not found: {args.selectors_json}"}))
        sys.exit(1)

    if not os.path.exists(args.snapshot):
        print(json.dumps({"error": f"Snapshot file not found: {args.snapshot}"}))
        sys.exit(1)

    try:
        with open(args.selectors_json, "r") as f:
            selectors = json.load(f)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"Invalid JSON: {e}"}))
        sys.exit(1)

    with open(args.snapshot, "r") as f:
        snapshot = f.read()

    testids = extract_testids_from_snapshot(snapshot)
    texts = extract_text_from_snapshot(snapshot)
    roles = extract_roles_from_snapshot(snapshot)

    found = []
    not_found = []

    for key, value in selectors.items():
        if check_selector_in_snapshot(value, testids, texts, roles):
            found.append(key)
        else:
            not_found.append(key)

    total = len(selectors)
    pass_rate = len(found) / total if total > 0 else 0

    result = {
        "total": total,
        "found": len(found),
        "found_keys": found,
        "not_found": not_found,
        "pass_rate": round(pass_rate, 2),
    }

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
