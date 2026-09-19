#!/usr/bin/env python3
"""Inspect the exact exported IPA, including both signed application bundles."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile

from evidence import CONFIG, digest, require, write


def run(*command):
    return subprocess.check_output(command)


def uuid_set(path):
    return {line.split()[1] for line in run("xcrun", "dwarfdump", "--uuid", str(path)).decode().splitlines() if line.startswith("UUID:")}


def main():
    ipa = Path("build/PicStrip.ipa")
    with tempfile.TemporaryDirectory(prefix="picstrip-ipa-") as directory:
        root = Path(directory)
        with zipfile.ZipFile(ipa) as archive:
            for name in archive.namelist():
                require(not name.startswith("/") and ".." not in Path(name).parts, "Unsafe IPA member")
            archive.extractall(root)
        apps = list((root / "Payload").glob("*.app"))
        require(len(apps) == 1, "Expected one main application")
        applications = [apps[0], *apps[0].glob("PlugIns/*.appex")]
        records, certificates = [], set()
        dsym_root = Path("build/PicStrip.xcarchive/dSYMs")
        available_symbols = set()
        for symbol in dsym_root.glob("*.dSYM"):
            available_symbols |= uuid_set(symbol)
        for app in applications:
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            info = plistlib.loads((app / "Info.plist").read_bytes())
            bundle = info["CFBundleIdentifier"]
            require(bundle in CONFIG["bundle_ids"], "Unexpected application bundle")
            require(info["CFBundleShortVersionString"] == os.environ["VERSION"], "Marketing version mismatch")
            require(info["CFBundleVersion"] == os.environ["BUILD_NUMBER"], "Build number mismatch")
            require(info.get("ITSAppUsesNonExemptEncryption") is False, "Export compliance missing from exported app")
            require(info.get("DTXcodeBuild") == CONFIG["xcode"]["build"], "IPA built by unexpected Xcode")
            require(info.get("DTSDKName") == "iphoneos" + CONFIG["xcode"]["sdk"], "IPA built by unexpected SDK")
            privacy = plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())
            require(privacy.get("NSPrivacyTracking") is False and "NSPrivacyAccessedAPITypes" in privacy, "Missing/invalid privacy manifest")
            profile = plistlib.loads(run("security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")))
            require(profile["ExpirationDate"] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), "Expired provisioning profile")
            require(not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"), "Not an App Store profile")
            entitlements = plistlib.loads(run("codesign", "--display", "--entitlements", ":-", str(app)))
            require(entitlements.get("application-identifier") == f"{CONFIG['team_id']}.{bundle}", "Application identity mismatch")
            require(entitlements.get("com.apple.developer.team-identifier") == CONFIG["team_id"], "Signing team mismatch")
            require(entitlements.get("get-task-allow", False) is False, "Debug entitlement in release")
            require(entitlements.get("com.apple.security.application-groups") == [CONFIG["app_group"]], "App group mismatch")
            require(profile["Entitlements"]["application-identifier"] == entitlements["application-identifier"], "Profile identity mismatch")
            executable = app / info["CFBundleExecutable"]
            uuids = uuid_set(executable)
            require(uuids and uuids <= available_symbols, "Missing matching dSYMs")
            certs = [hashlib.sha256(cert).hexdigest() for cert in profile["DeveloperCertificates"]]
            certificate_prefix = str(root / f"signing-certificate-{len(records)}-")
            run("codesign", "--display", "--extract-certificates", certificate_prefix, str(app))
            leaf_digest = digest(certificate_prefix + "0")
            require(leaf_digest in certs, "Signing certificate is not authorized by embedded profile")
            certificates.add(leaf_digest)
            records.append({"bundle_id": bundle, "version": info["CFBundleShortVersionString"],
                            "build_number": info["CFBundleVersion"], "path": app.relative_to(root).as_posix(),
                            "executable_sha256": digest(executable), "binary_uuids": sorted(uuids),
                            "profile_uuid": profile["UUID"], "profile_sha256": digest(app / "embedded.mobileprovision"),
                            "profile_expiration": profile["ExpirationDate"].isoformat(), "certificate_sha256": leaf_digest})
        require({r["bundle_id"] for r in records} == set(CONFIG["bundle_ids"]), "Missing application/extension")
        embedded = []
        for file in sorted(root.rglob("*")):
            if file.is_file() and (file.suffix == ".dylib" or file.parent.suffix == ".framework" and file.name == file.parent.stem):
                embedded.append({"path": file.relative_to(root).as_posix(), "sha256": digest(file)})
        inventory = {"schema_version": 1, "ipa_sha256": digest(ipa), "applications": records, "embedded_components": embedded,
                     "runtime_dependency_policy": "Apple SDK frameworks are platform dependencies; npm/Ruby/Python packages are build tools, not shipped app dependencies."}
        write("build/release/ipa-inventory.json", inventory)
        signing = {"match_commit": os.environ["MATCH_COMMIT"], "certificate_sha256": sorted(certificates),
                   "profiles": [{k: r[k] for k in ("bundle_id", "profile_uuid", "profile_sha256", "profile_expiration")} for r in records]}
        write("build/release/signing-env.json", signing)


if __name__ == "__main__":
    main()
