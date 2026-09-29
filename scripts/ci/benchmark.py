#!/usr/bin/env python3
"""Compatibility entrypoint; implementation belongs to the pinned platform."""
from pathlib import Path
import subprocess
import sys

raise SystemExit(subprocess.call([sys.executable, str(Path(__file__).resolve().parents[1] / 'ios_release.py'), 'benchmark', *sys.argv[1:]]))
