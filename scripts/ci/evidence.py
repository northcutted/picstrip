#!/usr/bin/env python3
"""Strict, dependency-free release evidence validation. Signatures are verified separately."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import struct
import tarfile
import xml.etree.ElementTree as ET

CONFIG = json.loads(Path(__file__).with_name("config.json").read_text())
CHECKS = ("lint", "analyze", "test", "test-ios26")
REQUIRED = {"PicStrip.ipa", "build-env.json", "signing-env.json", "ipa-inventory.json",
            "qa-results.tar.gz", "qa-manifest.json", "source.spdx.json", "ipa.spdx.json",
            "release-notes.md", "release-source.tar.zst", "app-store-metadata.tar.zst",
            "app-store-screenshots.tar.zst", "screenshots-manifest.json"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def digest(path):
    with Path(path).open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def asset(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), f"Missing or unsafe asset: {path}")
    return {"name": path.name, "sha256": digest(path), "bytes": path.stat().st_size}


def identity(data):
    require(data.get("schema_version") == 2, "Unsupported manifest schema")
    require(data.get("repository") == CONFIG["repository"], "Wrong repository")
    require(data.get("source_ref") == "refs/heads/main", "Release source must be main")
    require(re.fullmatch(r"[0-9a-f]{40}", data.get("source_sha", "")), "Invalid source SHA")
    require(re.fullmatch(r"\d+\.\d+\.\d+", data.get("version", "")), "Invalid marketing version")
    require(data.get("tag") == "v" + data["version"], "Tag/version mismatch")
    require(re.fullmatch(r"[1-9]\d{0,3}\.[1-9]\d?", data.get("build_number", "")), "Invalid build number")
    require(all(re.fullmatch(r"[1-9]\d*", str(data.get(k, ""))) for k in ("run_id", "run_attempt")), "Missing run identity")


def context():
    data = {"schema_version": 2, "repository": CONFIG["repository"], "source_ref": "refs/heads/main",
            "source_sha": os.environ["SOURCE_SHA"], "version": os.environ["VERSION"],
            "tag": "v" + os.environ["VERSION"], "build_number": os.environ["BUILD_NUMBER"],
            "run_id": os.environ["RELEASE_RUN_ID"], "run_attempt": os.environ["RELEASE_RUN_ATTEMPT"]}
    identity(data)
    return data


def verify_assets(root, entries):
    require(isinstance(entries, list) and entries, "No assets declared")
    names = set()
    for entry in entries:
        name = entry.get("name", "")
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name), "Unsafe asset name")
        require(name not in names, f"Duplicate asset: {name}")
        names.add(name)
        require(asset(Path(root) / name) == entry, f"Asset digest/size mismatch: {name}")
    return names


def validate_manifest(root, filename, source=None, tag=None, final=False):
    data = read(Path(root) / filename)
    identity(data)
    if source:
        require(data["source_sha"] == source, "Wrong source commit")
    if tag:
        require(data["tag"] == tag, "Wrong release tag")
    names = verify_assets(root, data["artifacts"])
    require(REQUIRED <= names, f"Missing release assets: {sorted(REQUIRED - names)}")
    ipa = next(x for x in data["artifacts"] if x["name"] == "PicStrip.ipa")
    require(data.get("ipa_sha256") == ipa["sha256"], "IPA identity mismatch")
    validate_qa_summary(read(Path(root) / "qa-manifest.json"), data["source_sha"])
    if final:
        require({"release-build-manifest.json", "testflight-status.json", "provenance.intoto.jsonl"} <= names,
                "Missing build provenance or upload receipt")
        original = validate_manifest(root, "release-build-manifest.json", source=data["source_sha"])
        for key in ("source_sha", "version", "build_number", "run_id", "run_attempt", "ipa_sha256"):
            require(data[key] == original[key], f"Build/final manifest mismatch: {key}")
        status = read(Path(root) / "testflight-status.json")
        validate_status(status, data)
        require(data.get("app_store_build_id") == status["app_store_build_id"], "App Store build identity mismatch")
        require(data.get("processing_state") == "VALID", "Build has not finished processing")
    return data


def validate_status(status, data):
    for key in ("version", "build_number", "source_sha", "ipa_sha256"):
        require(status.get(key) == data[key], f"Upload receipt mismatch: {key}")
    require(status.get("processing_state") == "VALID", "App Store build is not VALID")
    require(isinstance(status.get("app_store_build_id"), str) and status["app_store_build_id"], "Missing App Store build ID")


def validate_qa_summary(summary, source):
    require(summary.get("source_sha") == source, "QA source mismatch")
    require(set(summary.get("checks", {})) == set(CHECKS), "Incomplete QA evidence")
    for name, result in summary["checks"].items():
        require(result.get("status") == 0, f"Failed QA: {name}")
        if name.startswith("test"):
            require(result.get("executed", 0) > 0, f"No executed tests: {name}")
            require(result.get("failures") == 0, f"Failed tests: {name}")


def qa(root, output, source):
    checks = {}
    for name in CHECKS:
        result = read(Path(root) / name / "result.json")
        require(result.get("check") == name and result.get("source_sha") == source, f"Wrong QA identity: {name}")
        if name.startswith("test"):
            report = ET.parse(Path(root) / name / "report.junit")
            cases = list(report.iter("testcase"))
            skipped = sum(c.find("skipped") is not None for c in cases)
            failures = sum(c.find("failure") is not None or c.find("error") is not None for c in cases)
            result.update(executed=len(cases) - skipped, skipped=skipped, failures=failures)
        checks[name] = result
    summary = {"source_sha": source, "checks": checks}
    validate_qa_summary(summary, source)
    write(Path(output) / "qa-manifest.json", summary)
    with tarfile.open(Path(output) / "qa-results.tar.gz", "w:gz") as archive:
        archive.add(root, arcname="qa-results")


def screenshots(root, output):
    root = Path(root)
    require(root.is_dir(), "Missing screenshot directory")
    require({p.name for p in root.iterdir() if p.is_dir()} == set(CONFIG["locales"]), "Screenshot locale coverage mismatch")
    files = []
    for locale in CONFIG["locales"]:
        expected = set()
        for family, spec in CONFIG["screenshot_classes"].items():
            candidates = [name for name in spec["names"]
                          if all((root / locale / f"{name}-{screen}.png").is_file() for screen in CONFIG["screens"])]
            require(len(candidates) == 1, f"Incomplete/ambiguous {locale} {family} screenshots")
            for screen in CONFIG["screens"]:
                name = f"{candidates[0]}-{screen}.png"
                expected.add(name)
                path = root / locale / name
                with path.open("rb") as image:
                    header = image.read(24)
                require(header[:8] == b"\x89PNG\r\n\x1a\n" and header[12:16] == b"IHDR", f"Invalid PNG or LFS pointer: {path}")
                require(list(struct.unpack(">II", header[16:24])) in spec["sizes"], f"Wrong screenshot dimensions: {path}")
                record = asset(path)
                record["name"] = f"{locale}/{name}"
                files.append(record)
        require({p.name for p in (root / locale).iterdir()} == expected,
                f"Unexpected screenshot files in {locale}")
    write(output, {"schema_version": 1, "files": files})


def metadata(root):
    root = Path(root)
    limits = {"name.txt": 30, "subtitle.txt": 30, "keywords.txt": 100,
              "description.txt": 4000, "promotional_text.txt": 170, "release_notes.txt": 4000}
    for locale in CONFIG["locales"]:
        for name, limit in limits.items():
            file = root / locale / name
            if name in ("description.txt", "release_notes.txt"):
                require(file.is_file() and file.read_text().strip(), f"Missing metadata: {file}")
            if file.is_file():
                require(len(file.read_text().rstrip()) <= limit, f"Metadata exceeds {limit} characters: {file}")


def extract(archive_path, output, prefix):
    """Extract only regular files/directories below an expected prefix; never links."""
    output = Path(output)
    with tarfile.open(archive_path) as archive:
        members = archive.getmembers()
        seen = set()
        for member in members:
            name = member.name.rstrip("/")
            parts = PurePosixPath(name).parts
            require(not name.startswith("/") and ".." not in parts and name not in seen, "Unsafe archive path")
            require(name == prefix or name.startswith(prefix + "/"), "Unexpected archive root")
            require(member.isfile() or member.isdir(), "Archive links/devices are forbidden")
            require(member.size <= 100 * 1024 * 1024, "Oversized archive member")
            destination = output / name
            require(output.resolve() in destination.resolve().parents, "Archive escapes destination")
            seen.add(name)
        require(sum(m.size for m in members) <= 1024 * 1024 * 1024, "Archive exceeds size limit")
        for member in members:
            destination = output / member.name
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, destination.open("wb") as target:
                    import shutil
                    shutil.copyfileobj(source, target)


def build(root):
    root = Path(root)
    data = context()
    for name in ("build", "package", "qa", "sbom"):
        verify_assets(root, read(root / f"{name}-checksums.json"))
    validate_qa_summary(read(root / "qa-manifest.json"), data["source_sha"])
    inventory = read(root / "ipa-inventory.json")
    require(inventory["ipa_sha256"] == digest(root / "PicStrip.ipa"), "Inventory identifies another IPA")
    require({c["bundle_id"] for c in inventory["applications"]} == set(CONFIG["bundle_ids"]), "Incomplete IPA inventory")
    for app in inventory["applications"]:
        require(app["version"] == data["version"] and app["build_number"] == data["build_number"], "IPA version mismatch")
    data["ipa_sha256"] = inventory["ipa_sha256"]
    data["artifacts"] = [asset(p) for p in sorted(root.iterdir()) if p.is_file()]
    write(root / "release-build-manifest.json", data)
    validate_manifest(root, "release-build-manifest.json")


def finalize(root):
    root = Path(root)
    data = validate_manifest(root, "release-build-manifest.json")
    status = read(root / "testflight-status.json")
    validate_status(status, data)
    data.update(app_store_build_id=status["app_store_build_id"], processing_state="VALID")
    data["artifacts"] = [asset(p) for p in sorted(root.iterdir()) if p.is_file() and p.name not in ("release-manifest.json", "release-attestation.jsonl")]
    write(root / "release-manifest.json", data)
    validate_manifest(root, "release-manifest.json", final=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["checksums", "qa", "screenshots", "metadata", "extract", "build", "finalize", "verify"])
    parser.add_argument("root")
    parser.add_argument("--output")
    parser.add_argument("--source")
    parser.add_argument("--tag")
    parser.add_argument("--prefix")
    parser.add_argument("--final", action="store_true")
    args = parser.parse_args()
    if args.command == "checksums":
        write(args.output, [asset(p) for p in sorted(Path(args.root).iterdir()) if p.is_file() and p.resolve() != Path(args.output).resolve()])
    elif args.command == "qa":
        qa(args.root, args.output, args.source)
    elif args.command == "screenshots":
        screenshots(args.root, args.output)
    elif args.command == "metadata":
        metadata(args.root)
    elif args.command == "extract":
        extract(args.root, args.output, args.prefix)
    elif args.command == "build":
        build(args.root)
    elif args.command == "finalize":
        finalize(args.root)
    else:
        data = validate_manifest(args.root, "release-manifest.json" if args.final else "release-build-manifest.json", args.source, args.tag, args.final)
        if os.getenv("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as out:
                for key in ("version", "build_number", "source_sha", "run_id", "run_attempt", "ipa_sha256"):
                    out.write(f"{key}={data[key]}\n")


if __name__ == "__main__":
    main()
