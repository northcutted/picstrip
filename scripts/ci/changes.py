#!/usr/bin/env python3
"""Conservative change selection and the required CI gate; standard library only."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def full():
    return dict(qa=True, screenshots=True, prepare=True, store=True)


def screenshot_devices(config):
    devices = config.get("screenshot_devices")
    if not isinstance(devices, list) or not devices or any(not isinstance(device, str) or not device.strip() or "," in device for device in devices) or len(set(devices)) != len(devices):
        raise ValueError("Screenshot matrix requires unique, nonempty device names without commas")
    return devices


def classify(paths):
    result = dict(qa=False, screenshots=False, prepare=False, store=False)
    if not paths:
        return full()
    for path in paths:
        if not path or path.startswith("/") or ".." in path.split("/"):
            return full()
        if re.match(r"^(docs/|\.github/ISSUE_TEMPLATE/)", path) or re.fullmatch(r"(README|DEVELOPMENT|LICENSE|CHANGELOG)(\.md|\.txt)?", path):
            continue
        if re.match(r"^fastlane/(metadata/|screenshots/processed/)", path):
            result.update(prepare=True, store=True)
            continue
        if re.match(r"^(PicStrip/|PicStripShareExtension/|PicStripTests/|PicStripUITests/|PicStripCore/|PicStrip\.xcodeproj/)", path) or path == "PicStrip-Info.plist":
            result.update(qa=True, prepare=True)
            if not path.startswith("PicStripTests/"):
                result["screenshots"] = True
            continue
        return full()
    return result


def gate(jobs, selection):
    for name in ["changes", "policy"]:
        if jobs.get(name, {}).get("result") != "success":
            raise ValueError(f"{name} did not pass")
    for flag in ["qa", "screenshots", "store"]:
        if selection.get(flag) not in {"true", "false"}:
            raise ValueError(f"Invalid {flag} decision")
    for job in ["qa", "screenshots"]:
        expected = "success" if selection[job] == "true" else "skipped"
        if jobs.get(job, {}).get("result") != expected:
            raise ValueError(f"{job}: expected {expected}, got {jobs.get(job, {}).get('result')}")


def compare(event_name, event, git=None):
    if event_name == "workflow_dispatch":
        return {**full(), "reason": "Manual run requests every check"}
    if event_name == "pull_request":
        pull = event.get("pull_request") or {}
        base, head = (pull.get("base") or {}).get("sha"), (pull.get("head") or {}).get("sha")
    elif event_name == "push":
        base, head = event.get("before"), event.get("after")
    else:
        return {**full(), "reason": "Unknown event"}
    if not all(isinstance(value, str) and re.fullmatch(r"[a-f0-9]{40}", value) and value != "0" * 40 for value in [base, head]):
        return {**full(), "reason": "No reliable comparison commits"}
    git = git or (lambda *args: subprocess.check_output(["git", *args], text=True))
    try:
        separator = "..." if event_name == "pull_request" else ".."
        paths = list(filter(None, git("diff", "--name-only", "--no-renames", "-z", base + separator + head).split("\0")))
        return {**classify(paths), "reason": f"{len(paths)} changed paths", "paths": paths}
    except (OSError, subprocess.SubprocessError, ValueError):
        return {**full(), "reason": "Comparison unavailable; running every check"}


def main():
    if sys.argv[1:2] == ["examples"]:
        print(json.dumps([{"path": path, **classify([path])} for path in json.loads(sys.argv[2])]))
    elif sys.argv[1:2] == ["gate"]:
        gate(json.loads(os.environ["JOBS"]), json.loads(os.environ["SELECTION"]))
        print("Required checks passed; every skip matches the change classification.")
    else:
        selection = compare(os.environ["GITHUB_EVENT_NAME"], json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()))
        devices = screenshot_devices(json.loads(Path(".github/ios-release.json").read_text()))
        with open(os.environ["GITHUB_OUTPUT"], "a") as file:
            file.write("".join(f"{flag}={str(selection[flag]).lower()}\n" for flag in full()))
            file.write(f"screenshot_devices={json.dumps(devices)}\n")
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as file:
            file.write(f"Checks selected: QA={str(selection['qa']).lower()}, UI smoke={str(selection['screenshots']).lower()}, release candidate={str(selection['prepare']).lower()}. {selection['reason']}.\n")


if __name__ == "__main__":
    main()
