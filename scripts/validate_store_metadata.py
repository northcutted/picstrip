#!/usr/bin/env python3
"""Validate curated per-locale App Store text without changing it."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
config = json.loads((ROOT / '.github/ios-release.json').read_text())
base = ROOT / config['metadata_path']
limits = {'name': 30, 'subtitle': 30, 'keywords': 100, 'promotional_text': 170,
          'description': 4000, 'release_notes': 4000}
errors = []
english_notes = (base / 'en-US/release_notes.txt').read_text().strip()
for locale in config['locales']:
    for field, maximum in limits.items():
        path = base / locale / f'{field}.txt'
        value = path.read_text().strip() if path.is_file() else ''
        if not value or len(value) > maximum:
            errors.append(f'{locale}/{field}: missing, empty, or exceeds {maximum} characters')
        if field == 'release_notes':
            if re.search(r'\b(?:CI|workflow|runner|semantic-release|xcodebuild)\b', value, re.I):
                errors.append(f'{locale}: release notes contain engineering changelog text')
            if locale != 'en-US' and value == english_notes:
                errors.append(f'{locale}: release notes duplicate English instead of being localized')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'Curated App Store metadata passed for {len(config["locales"])} locales.')
