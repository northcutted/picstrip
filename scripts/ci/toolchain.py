#!/usr/bin/env python3
"""Select an exact installed Xcode and resolve simulator IDs, without defaults."""
import argparse
import json
import os
from pathlib import Path
import subprocess

CONFIG = json.loads(Path(__file__).with_name("config.json").read_text())


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compatibility", action="store_true")
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--destinations-json", action="store_true")
    args = parser.parse_args()
    expected = CONFIG["compatibility" if args.compatibility else "xcode"]
    os.environ["DEVELOPER_DIR"] = expected["path"]
    actual = run("xcodebuild", "-version").splitlines()
    if actual != [f"Xcode {expected['version']}", f"Build version {expected['build']}"]:
        raise SystemExit(f"Unexpected Xcode: {actual}; required {expected}")
    sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-version")
    if sdk != expected["sdk"]:
        raise SystemExit(f"Unexpected iPhoneOS SDK {sdk}")
    runtime_key = "com.apple.CoreSimulator.SimRuntime.iOS-" + expected["runtime"].replace(".", "-")
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"].get(runtime_key, [])
    names = CONFIG["screenshot_devices"] if args.screenshots else [CONFIG["test_device"]]
    resolved = {}
    for name in names:
        matches = [d["udid"] for d in devices if d["name"] == name and d.get("isAvailable")]
        if len(matches) != 1:
            raise SystemExit(f"Expected one {name} on {runtime_key}; found {matches}")
        resolved[name] = matches[0]
    values = {"DEVELOPER_DIR": expected["path"], "SIMULATOR_RUNTIME": expected["runtime"],
              "SIMULATOR_UDIDS": json.dumps(resolved)}
    if not args.screenshots:
        values["TEST_DESTINATION"] = f"platform=iOS Simulator,id={resolved[CONFIG['test_device']]}"
    if os.getenv("GITHUB_ENV"):
        with open(os.environ["GITHUB_ENV"], "a") as out:
            for key, value in values.items():
                out.write(f"{key}={value}\n")
    Path("build").mkdir(exist_ok=True)
    environment = {**expected, "sdk": sdk, "swift": run("xcrun", "swift", "--version"),
                   "macos": run("sw_vers", "-productVersion"), "architecture": run("uname", "-m"),
                   "runner_image": os.getenv("ImageVersion"), "runner_image_os": os.getenv("ImageOS"),
                   "simulators": resolved}
    Path("build/build-env.json").write_text(json.dumps(environment, indent=2) + "\n")
    print(json.dumps(resolved if args.destinations_json else environment, indent=2))


if __name__ == "__main__":
    main()
