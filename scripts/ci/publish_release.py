#!/usr/bin/env python3
"""Publish a complete draft; reject conflicting retries instead of replacing assets."""
import json
import os
from pathlib import Path
import subprocess

from evidence import CONFIG, require, validate_manifest

root = Path("release-assets")
manifest = validate_manifest(root, "release-manifest.json", final=True)
repository, tag = CONFIG["repository"], manifest["tag"]


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


existing = subprocess.run(["gh", "api", f"repos/{repository}/releases/tags/{tag}"], text=True, capture_output=True)
settings = json.loads(gh("api", f"repos/{repository}/immutable-releases"))
require(settings.get("enabled") is True, "Enable immutable releases before creating or publishing a draft")
if existing.returncode == 0:
    release = json.loads(existing.stdout)
    require(release["target_commitish"] == manifest["source_sha"], "Release tag target conflicts with this build")
else:
    require("404" in existing.stderr, "Cannot determine whether release already exists")
    gh("release", "create", tag, "--repo", repository, "--draft", "--target", manifest["source_sha"],
       "--title", tag, "--notes-file", str(root / "release-notes.md"))
    release = json.loads(gh("api", f"repos/{repository}/releases/tags/{tag}"))

from evidence import digest
remote = {a["name"]: a for a in release["assets"]}
expected = {p.name: p for p in root.iterdir() if p.is_file()}
require(not set(remote) - set(expected), "Unexpected assets already attached to release")
for name, path in sorted(expected.items()):
    if name in remote:
        require(remote[name].get("digest") == "sha256:" + digest(path), f"Conflicting existing release asset: {name}")
    else:
        require(release["draft"], "Cannot add assets to a published release")
        gh("release", "upload", tag, str(path), "--repo", repository)
readback = json.loads(gh("api", f"repos/{repository}/releases/tags/{tag}"))
require({a["name"]: a.get("digest") for a in readback["assets"]} == {name: "sha256:" + digest(path) for name, path in expected.items()}, "Release asset readback mismatch")
if release["draft"]:
    gh("release", "edit", tag, "--repo", repository, "--draft=false")
published = json.loads(gh("api", f"repos/{repository}/releases/tags/{tag}"))
require(published.get("immutable") is True and not published["draft"], "Repository immutable releases must be enabled before publishing")
print(published["html_url"])
