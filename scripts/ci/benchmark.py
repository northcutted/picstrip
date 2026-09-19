#!/usr/bin/env python3
"""Read completed runs, separating queue time, execution, and Apple processing."""
import argparse
import datetime
import json
import statistics
import subprocess

from pathlib import Path

CONFIG = json.loads((Path(__file__).resolve().parents[2] / ".github/ios-release.json").read_text())

def require(condition, message):
    if not condition: raise ValueError(message)

parser = argparse.ArgumentParser()
parser.add_argument("runs", nargs="+", type=int)
parser.add_argument("--baseline-test-seconds", type=float)
args = parser.parse_args()
require(len(args.runs) >= 5, "Use at least five comparable completed runs")


def get(path): return json.loads(subprocess.check_output(["gh", "api", path], text=True))
def seconds(start, end): return (datetime.datetime.fromisoformat(end.replace("Z", "+00:00")) - datetime.datetime.fromisoformat(start.replace("Z", "+00:00"))).total_seconds()


rows = []
for run_id in args.runs:
    base = f"repos/{CONFIG['repository']}/actions/runs/{run_id}"
    run = get(base)
    require(run["status"] == "completed" and run["conclusion"] == "success", f"Run {run_id} did not pass")
    jobs = get(base + "/jobs?per_page=100")["jobs"]
    rows.append({"run_id": run_id, "sha": run["head_sha"], "initial_queue_seconds": seconds(run["created_at"], min(j["started_at"] for j in jobs)),
                 "elapsed_seconds": seconds(run["created_at"], max(j["completed_at"] for j in jobs)),
                 "jobs": [{"name": job["name"], "seconds": seconds(job["started_at"], job["completed_at"])} for job in jobs]})
require(len({r["sha"] for r in rows}) == 1, "Benchmark runs must use the same source revision")
test_times = [job["seconds"] for row in rows for job in row["jobs"] if job["name"].endswith(" / test")]
require(len(test_times) == len(rows), "Expected one iOS 27 test job per run")
median = statistics.median(test_times)
print(json.dumps({"runs": rows, "median_test_seconds": median,
                  "meets_15_percent_improvement": bool(args.baseline_test_seconds and median <= args.baseline_test_seconds * .85)}, indent=2))
