#!/usr/bin/env python3
"""Compute a test quality score (0-100) for a generated E2E test.

This script is IMMUTABLE -- agents must NEVER modify it.
It is the single source of truth for test quality, analogous to
autoresearch's prepare.py / evaluate_bpb().

Usage:
    python3 scripts/compute-quality-score.py <test-file> <selectors-json> [actions-file]

Output: JSON to stdout
    {"score": 82, "grade": "B", "components": {...}}
"""

import json
import re
import sys
import os


def read_file(path):
    with open(path, "r") as f:
        return f.read()


def score_selector_robustness(selectors_data):
    """25 points: % of selectors using data-testid as primary."""
    if not selectors_data:
        return 0.0, {"total": 0, "data_testid_primary": 0}

    total = len(selectors_data)
    testid_primary = 0
    for key, val in selectors_data.items():
        # Primary selector is before the first pipe
        primary = val.split("|")[0].strip()
        if "data-testid" in primary or "data-cy" in primary:
            testid_primary += 1

    rate = testid_primary / total if total > 0 else 0
    return rate, {"total": total, "data_testid_primary": testid_primary}


def score_assertion_coverage(test_content):
    """20 points: % of feature tests (#3+) that contain expect()."""
    # Find all test blocks with their numbers
    test_blocks = re.findall(
        r'test\(\s*"#(\d+)\s+[^"]*"\s*,\s*async\s*\(\)\s*=>\s*\{(.*?)\}\s*\)',
        test_content,
        re.DOTALL,
    )

    feature_tests = [(num, body) for num, body in test_blocks if int(num) >= 3]
    if not feature_tests:
        return 0.0, {"feature_tests": 0, "with_assertions": 0}

    with_assertions = 0
    for num, body in feature_tests:
        if "expect(" in body or "expect.soft(" in body:
            with_assertions += 1

    rate = with_assertions / len(feature_tests)
    return rate, {
        "feature_tests": len(feature_tests),
        "with_assertions": with_assertions,
    }


def score_assertion_messages(test_content):
    """10 points: % of expect() calls that include an error message arg."""
    # Match expect(...) and expect.soft(...) calls
    # With message: expect(thing, "message").toXxx()
    # Without: expect(thing).toXxx()
    all_expects = re.findall(
        r"expect(?:\.soft)?\s*\(", test_content
    )
    total = len(all_expects)
    if total == 0:
        return 1.0, {"total": 0, "with_message": 0}

    # Count expects with message (two arguments before closing paren + .toXxx)
    # Pattern: expect(expr, "message") or expect.soft(expr, "message")
    with_msg = len(
        re.findall(
            r'expect(?:\.soft)?\s*\([^)]*,\s*["`\']',
            test_content,
        )
    )
    # Also count template literals
    with_msg += len(
        re.findall(
            r"expect(?:\.soft)?\s*\([^)]*,\s*`",
            test_content,
        )
    )
    # Deduplicate (template literals may be caught by both)
    with_msg = min(with_msg, total)

    rate = with_msg / total
    return rate, {"total": total, "with_message": with_msg}


def score_action_reuse(test_content, actions_content):
    """15 points: ratio of action function calls vs inline page.X() calls."""
    # Count inline page interactions in test file
    inline_calls = len(
        re.findall(
            r"page\.\s*(?:click|fill|goto|locator|waitForSelector|waitForTimeout|waitForLoadState|hover|dblclick|check|uncheck|selectOption|press)\s*\(",
            test_content,
        )
    )

    # Count action function calls (imported functions called in test)
    # Look for require() imports of action files
    action_imports = re.findall(
        r"require\s*\(\s*[\"'].*?/actions/[^\"']+[\"']\s*\)", test_content
    )

    # Count function calls that aren't page.X or expect
    # These are likely action function calls
    action_calls = len(
        re.findall(
            r"await\s+(?!page\.|expect|navigation|verifyLoginPage|closeWhatsNew)[a-zA-Z]\w*\s*\(",
            test_content,
        )
    )
    # Also count the standard action calls
    action_calls += len(
        re.findall(
            r"await\s+(?:navigation|verifyLoginPage|closeWhatsNew|openReportsPage|applyFilter|clearFilters|verifyReportCount)\s*\(",
            test_content,
        )
    )

    total = inline_calls + action_calls
    if total == 0:
        return 0.5, {"inline_calls": 0, "action_calls": 0}

    rate = action_calls / total
    return rate, {"inline_calls": inline_calls, "action_calls": action_calls}


def score_convention_compliance(test_content):
    """15 points: checks for CommonJS, serial mode, hooks, formatting."""
    checks = {
        "commonjs": "require(" in test_content and "import " not in test_content.split("require(")[0],
        "serial_mode": 'mode: "serial"' in test_content,
        "hooks_imported": "setBeforeAll" in test_content and "setAfterAll" in test_content,
        "hooks_used": "test.beforeAll" in test_content and "test.afterAll" in test_content,
        "double_quotes": test_content.count('"') > test_content.count("'"),
        "test_numbering": bool(re.search(r'test\(\s*"#1\s', test_content)),
        "login_flow": "verifyLoginPage" in test_content,
        "navigate_first": bool(re.search(r'test\(\s*"#1\s.*[Nn]avigate', test_content)),
        "no_networkidle": "networkidle" not in test_content,
        "no_es_import": not bool(re.match(r"^\s*import\s+", test_content, re.MULTILINE)),
    }

    passed = sum(1 for v in checks.values() if v)
    rate = passed / len(checks)
    return rate, checks


def score_test_isolation(test_content):
    """10 points: no shared mutable state modified between tests."""
    # Check for let variables declared outside test blocks that are reassigned inside
    # Find let declarations at module level
    module_lets = re.findall(r"^let\s+(\w+)", test_content, re.MULTILINE)

    # Check if any are reassigned inside test blocks (not counting page/context which are expected)
    expected_shared = {"page", "context"}
    violations = []
    for var in module_lets:
        if var in expected_shared:
            continue
        # Check if variable is reassigned inside a test() block
        test_bodies = re.findall(
            r'test\(\s*"[^"]*"\s*,\s*async\s*\(\)\s*=>\s*\{(.*?)\}\s*\)',
            test_content,
            re.DOTALL,
        )
        for body in test_bodies:
            if re.search(rf"\b{var}\s*=\s*", body):
                violations.append(var)
                break

    rate = 1.0 if not violations else max(0, 1.0 - len(violations) * 0.25)
    return rate, {"shared_vars": len(module_lets), "violations": violations}


def score_selector_fallbacks(selectors_data):
    """5 points: % of selectors with pipe (|) fallback."""
    if not selectors_data:
        return 0.0, {"total": 0, "with_fallback": 0}

    total = len(selectors_data)
    with_fallback = sum(1 for v in selectors_data.values() if "|" in v)
    rate = with_fallback / total if total > 0 else 0
    return rate, {"total": total, "with_fallback": with_fallback}


def compute_score(test_file, selectors_file, actions_file=None):
    test_content = read_file(test_file)

    try:
        selectors_data = json.loads(read_file(selectors_file))
    except (json.JSONDecodeError, FileNotFoundError):
        selectors_data = {}

    actions_content = ""
    if actions_file and os.path.exists(actions_file):
        actions_content = read_file(actions_file)

    weights = {
        "selector_robustness": 25,
        "assertion_coverage": 20,
        "assertion_messages": 10,
        "action_reuse": 15,
        "convention_compliance": 15,
        "test_isolation": 10,
        "selector_fallbacks": 5,
    }

    components = {}

    rate, detail = score_selector_robustness(selectors_data)
    components["selector_robustness"] = {
        "weight": weights["selector_robustness"],
        "rate": round(rate, 2),
        "points": round(rate * weights["selector_robustness"], 1),
        "detail": detail,
    }

    rate, detail = score_assertion_coverage(test_content)
    components["assertion_coverage"] = {
        "weight": weights["assertion_coverage"],
        "rate": round(rate, 2),
        "points": round(rate * weights["assertion_coverage"], 1),
        "detail": detail,
    }

    rate, detail = score_assertion_messages(test_content)
    components["assertion_messages"] = {
        "weight": weights["assertion_messages"],
        "rate": round(rate, 2),
        "points": round(rate * weights["assertion_messages"], 1),
        "detail": detail,
    }

    rate, detail = score_action_reuse(test_content, actions_content)
    components["action_reuse"] = {
        "weight": weights["action_reuse"],
        "rate": round(rate, 2),
        "points": round(rate * weights["action_reuse"], 1),
        "detail": detail,
    }

    rate, detail = score_convention_compliance(test_content)
    components["convention_compliance"] = {
        "weight": weights["convention_compliance"],
        "rate": round(rate, 2),
        "points": round(rate * weights["convention_compliance"], 1),
        "detail": detail,
    }

    rate, detail = score_test_isolation(test_content)
    components["test_isolation"] = {
        "weight": weights["test_isolation"],
        "rate": round(rate, 2),
        "points": round(rate * weights["test_isolation"], 1),
        "detail": detail,
    }

    rate, detail = score_selector_fallbacks(selectors_data)
    components["selector_fallbacks"] = {
        "weight": weights["selector_fallbacks"],
        "rate": round(rate, 2),
        "points": round(rate * weights["selector_fallbacks"], 1),
        "detail": detail,
    }

    total_score = sum(c["points"] for c in components.values())
    total_score = round(total_score, 1)

    if total_score >= 90:
        grade = "A"
    elif total_score >= 80:
        grade = "B"
    elif total_score >= 70:
        grade = "C"
    elif total_score >= 60:
        grade = "D"
    else:
        grade = "F"

    return {"score": total_score, "grade": grade, "components": components}


def main():
    if len(sys.argv) < 3:
        print(
            "Usage: python3 scripts/compute-quality-score.py <test-file> <selectors-json> [actions-file]",
            file=sys.stderr,
        )
        sys.exit(1)

    test_file = sys.argv[1]
    selectors_file = sys.argv[2]
    actions_file = sys.argv[3] if len(sys.argv) > 3 else None

    result = compute_score(test_file, selectors_file, actions_file)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
