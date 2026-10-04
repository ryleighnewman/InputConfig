#!/usr/bin/env python3
"""Lint the Smart Preset catalog embedded in ExamplePresets.swift.

Reports:
  - groups of profiles whose rows (inputs, outputs, and notes) are identical,
    so a profile copied from another game can be checked for notes that name
    the other game's actions;
  - rows that list the same output twice (use repeatCount instead);
  - rows with an empty note.

Usage: python3 scripts/lint_smart_presets.py [--all]
Exit code 1 when a same-output row is found, 0 otherwise. Clone groups are
reported, not failed: many are shared genre layouts on purpose.
"""
import collections
import json
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "InputConfig/Resources/ExamplePresets.swift"


def load_profiles():
    text = SOURCE.read_text()
    marker = 'static let libraryJSON = """'
    start = text.index(marker) + len(marker)
    end = text.index('"""', start)
    return json.loads(text[start:end])


def main():
    show_all = "--all" in sys.argv
    profiles = load_profiles()
    groups = collections.defaultdict(list)
    doubled, unnoted = [], []
    for p in profiles:
        rows = p.get("bindings", [])
        key = json.dumps([(b["input"], b["outputs"], b.get("note", "")) for b in rows], sort_keys=True)
        groups[key].append(p["displayName"])
        for b in rows:
            outs = b.get("outputs", [])
            if len(outs) > 1 and len(set(outs)) == 1:
                doubled.append(f'{p["id"]}: {b["input"]} {outs}')
            if not b.get("note", "").strip():
                unnoted.append(f'{p["id"]}: {b["input"]}')

    clones = sorted((g for g in groups.values() if len(g) > 1), key=len, reverse=True)
    print(f"{len(profiles)} profiles")
    print(f"{sum(len(g) for g in clones)} profiles in {len(clones)} groups with identical rows and notes")
    for g in clones if show_all else clones[:15]:
        print(f"  {len(g)}: " + ", ".join(g))
    if not show_all and len(clones) > 15:
        print(f"  ... {len(clones) - 15} more groups (--all to list)")
    print(f"{len(doubled)} rows list the same output twice")
    for d in doubled:
        print("  " + d)
    print(f"{len(unnoted)} rows have no note")
    return 1 if doubled else 0


if __name__ == "__main__":
    sys.exit(main())
