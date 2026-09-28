#!/usr/bin/env bash
# Compatibility entry point: store notes are reviewed and translated in source.
# Engineering release notes remain in the GitHub release/changelog.
set -euo pipefail
python3 "$(dirname "$0")/validate_store_metadata.py"
