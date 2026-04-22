#!/usr/bin/env python3
"""Query experiments log to find what worked/failed for similar scenarios.

Like autoresearch's results.tsv reader -- helps agents avoid repeating
failed approaches and build on successful strategies.

Usage:
    python3 scripts/query-experiments.py [--file FILE] [--type TYPE] [--outcome OUTCOME] [--agent AGENT] [--feature KEYWORD] [--recent N]

Options:
    --file FILE       Path to experiments JSONL file (default: memory/experiments-index.jsonl)
    --type TYPE       Filter by experiment_type (selector_strategy, selector_fix, action_pattern, wait_strategy, test_logic_fix)
    --outcome OUTCOME Filter by outcome (pass, partial_pass, fail, error)
    --agent AGENT     Filter by agent name (code-writer, debug, etc.)
    --feature KEYWORD Filter by keyword in hypothesis field
    --ticket TICKET   Filter by ticket key (e.g., OXDEV-65901)
    --recent N        Return only the N most recent matching entries (default: all)

Output: JSON array to stdout
"""

import argparse
import json
import sys
import os


def load_jsonl(path):
    """Load JSONL file, skipping malformed lines."""
    entries = []
    if not os.path.exists(path):
        return entries
    with open(path, "r") as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                print(
                    f"Warning: skipping malformed line {line_num} in {path}",
                    file=sys.stderr,
                )
    return entries


def filter_entries(entries, args):
    """Apply filters to experiment entries."""
    filtered = entries

    if args.type:
        filtered = [e for e in filtered if e.get("experiment_type") == args.type]

    if args.outcome:
        filtered = [e for e in filtered if e.get("outcome") == args.outcome]

    if args.agent:
        filtered = [e for e in filtered if e.get("agent") == args.agent]

    if args.ticket:
        filtered = [e for e in filtered if e.get("ticket") == args.ticket]

    if args.feature:
        keyword = args.feature.lower()
        filtered = [
            e
            for e in filtered
            if keyword in e.get("hypothesis", "").lower()
            or keyword in e.get("ticket", "").lower()
            or keyword
            in json.dumps(e.get("metrics", {})).lower()
        ]

    # Sort by timestamp descending (most recent first)
    filtered.sort(key=lambda e: e.get("ts", ""), reverse=True)

    if args.recent:
        filtered = filtered[: args.recent]

    return filtered


def main():
    parser = argparse.ArgumentParser(
        description="Query experiments log for past outcomes"
    )
    parser.add_argument(
        "--file",
        default="memory/experiments-index.jsonl",
        help="Path to experiments JSONL file",
    )
    parser.add_argument("--type", help="Filter by experiment_type")
    parser.add_argument("--outcome", help="Filter by outcome")
    parser.add_argument("--agent", help="Filter by agent name")
    parser.add_argument("--feature", help="Filter by keyword in hypothesis")
    parser.add_argument("--ticket", help="Filter by ticket key")
    parser.add_argument("--recent", type=int, help="Return only N most recent entries")

    args = parser.parse_args()

    entries = load_jsonl(args.file)
    if not entries:
        print("[]")
        return

    filtered = filter_entries(entries, args)
    print(json.dumps(filtered, indent=2))


if __name__ == "__main__":
    main()
