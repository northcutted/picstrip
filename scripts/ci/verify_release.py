#!/usr/bin/env python3
"""Authenticate evidence before trusting its metadata or consuming its assets."""
import argparse
import json
import os
from pathlib import Path
import subprocess

from evidence import CONFIG, require, validate_manifest


def provenance_identity(statement, source):
    predicate = statement.get("predicate", {})
    config = predicate.get("invocation", {}).get("configSource", {})
    require(config.get("uri") == f"git+https://github.com/{CONFIG['repository']}@refs/heads/main", "Wrong SLSA source/workflow ref")
    require(config.get("digest", {}).get("sha1") == source, "Wrong SLSA source commit")
    require(config.get("entryPoint") == ".github/workflows/main.yml", "Wrong SLSA entrypoint")


def verify(root, source, tag=None, final=False):
    root = Path(root)
    filename = "release-manifest.json" if final else "release-build-manifest.json"
    bundle = "release-attestation.jsonl" if final else "build-attestation.jsonl"
    predicate = "https://northcutted.github.io/picstrip/attestations/release/v2" if final else "https://slsa.dev/provenance/v1"
    command = ["gh", "attestation", "verify", str(root / filename), "--bundle", str(root / bundle),
               "--repo", CONFIG["repository"], "--signer-workflow", f"github.com/{CONFIG['repository']}/.github/workflows/main.yml",
               "--source-ref", "refs/heads/main", "--source-digest", source, "--signer-digest", source,
               "--deny-self-hosted-runners", "--predicate-type", predicate]
    subprocess.run(command, check=True)
    manifest = validate_manifest(root, filename, source, tag, final)
    # The generic generator is the isolated Build L3 provenance authority.
    result = subprocess.check_output(["slsa-verifier", "verify-artifact", str(root / "release-build-manifest.json"),
                                      "--provenance-path", str(root / "provenance.intoto.jsonl"),
                                      "--source-uri", f"github.com/{CONFIG['repository']}", "--source-branch", "main", "--print-provenance"], text=True)
    provenance_identity(json.loads(result), source)
    environment = json.loads(result)["predicate"]["invocation"]["environment"]
    require(environment.get("github_run_id") == str(manifest["run_id"]), "Provenance came from another workflow run")
    # Rerunning failed jobs legitimately signs existing immutable outputs in a later attempt.
    require(int(environment.get("github_run_attempt", 0)) >= int(manifest["run_attempt"]), "Provenance predates this build")
    require(manifest["build_number"] == f"{environment.get('github_run_number')}.{manifest['run_attempt']}", "Build number does not identify the producing run")
    for field, variable in (("run_id", "RELEASE_RUN_ID"), ("run_attempt", "RELEASE_RUN_ATTEMPT"), ("version", "VERSION"), ("build_number", "BUILD_NUMBER")):
        if os.getenv(variable):
            require(str(manifest[field]) == os.environ[variable], f"Unexpected release context: {field}")
    subprocess.run(["slsa-verifier", "verify-artifact", str(root / "PicStrip.ipa"),
                    "--provenance-path", str(root / "provenance.intoto.jsonl"),
                    "--source-uri", f"github.com/{CONFIG['repository']}", "--source-branch", "main"], check=True)
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--source", required=True)
    parser.add_argument("--tag")
    parser.add_argument("--final", action="store_true")
    args = parser.parse_args()
    verify(args.root, args.source, args.tag, args.final)
