#!/usr/bin/env python3
"""Compose captured locales with the existing Python compositor."""
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    config = json.loads((ROOT / '.github/ios-release.json').read_text())
    captures = ROOT / 'fastlane/screenshots'
    locales = sorted(path.name for path in captures.iterdir()
                     if path.is_dir() and path.name in config['locales'])
    if not locales:
        raise ValueError('No captured locales to compose')
    shutil.rmtree(captures / 'Logs', ignore_errors=True)
    for locale in locales:
        shutil.rmtree(captures / 'processed' / locale, ignore_errors=True)
        subprocess.run([sys.executable, str(ROOT / 'scripts/process_screenshots.py'), '--locale', locale],
                       cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
