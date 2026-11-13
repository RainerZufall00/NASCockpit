#!/usr/bin/env python3
"""Checks the App Store texts in AppStore/metadata against the limits of App Store Connect.
Run from the repository root: python3 AppStore/Tools/check-lengths.py"""
import pathlib, sys

LIMITS = {"name.txt": 30, "subtitle.txt": 30, "promotional_text.txt": 170, "keywords.txt": 100,
          "description.txt": 4000, "release_notes.txt": 4000}
failed = False
for folder in sorted(pathlib.Path("AppStore/metadata").glob("*-*")):
    for file, limit in LIMITS.items():
        path = folder / file
        if not path.exists():
            continue
        text = path.read_text().strip()
        ok = len(text) <= limit and not (file == "keywords.txt" and ", " in text)
        failed |= not ok
        print(f"{'ok ' if ok else 'TOO LONG'} {folder.name}/{file}: {len(text)}/{limit}")
sys.exit(1 if failed else 0)
