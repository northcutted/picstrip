#!/usr/bin/env python3
"""Update all consumer pins together after independently reviewing a platform commit."""
import json
from pathlib import Path
import re
import sys

if len(sys.argv) != 2 or not re.fullmatch(r'[a-f0-9]{40}', sys.argv[1]):
    raise SystemExit('Usage: update_release_platform.py FULL_REVIEWED_PLATFORM_SHA')
sha = sys.argv[1]
root = Path(__file__).resolve().parents[1]
path = root / '.github/ios-release-platform.json'
config = json.loads(path.read_text())
old = config['revision']
for workflow in (root / '.github/workflows').glob('*.yml'):
    text = workflow.read_text()
    workflow.write_text(text.replace(old, sha))
config['revision'] = sha
path.write_text(json.dumps(config, indent=2) + '\n')
print('Updated consumer calls and producer pin; review the diff and run CI.')
