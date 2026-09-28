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
app_path = root / '.github/ios-release.json'
app = json.loads(app_path.read_text())
# Retain existing builds and permit old release callers to authenticate the new
# promoter through protected main policy. The pin change is reviewed as a whole.
approved = sorted(set(app.get('trusted_producer_revisions', []) + [old, sha]))
if len(approved) > 20:
    raise SystemExit('Review and retire unused producer revisions before updating the pin')
for workflow in (root / '.github/workflows').glob('*.yml'):
    text = workflow.read_text()
    workflow.write_text(text.replace(old, sha))
app['trusted_producer_revisions'] = approved
app_path.write_text(json.dumps(app, indent=2) + '\n')
config['revision'] = sha
path.write_text(json.dumps(config, indent=2) + '\n')
print('Updated consumer calls and producer pin; review the diff and run CI.')
