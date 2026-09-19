#!/usr/bin/env python3
"""Preserve exit status, streaming logs and a source-bound QA result."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

name, *command = sys.argv[1:]
root = Path("qa-results") / name
root.mkdir(parents=True, exist_ok=True)
with (root / "output.log").open("w") as log:
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in process.stdout:
        print(line, end="", flush=True)
        log.write(line)
    status = process.wait()
if name.startswith("test"):
    report = Path("build/test_output/report.junit")
    if report.is_file():
        shutil.copy2(report, root / "report.junit")
    else:
        status = status or 1
result = {"check": name, "status": status,
          "source_sha": os.environ.get("SOURCE_SHA", os.environ.get("GITHUB_SHA")),
          "run_id": os.environ.get("GITHUB_RUN_ID")}
(root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
sys.exit(status)
