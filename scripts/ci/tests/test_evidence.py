import copy
import io
import json
import os
from pathlib import Path
import struct
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import subprocess

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import evidence as e
from verify_release import provenance_identity
from verify_release import verify

SHA = "a" * 40


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.addCleanup(self.directory.cleanup)

    def test_assets_reject_tampering_missing_duplicate_and_traversal(self):
        file = self.root / "PicStrip.ipa"
        file.write_bytes(b"real ipa")
        record = e.asset(file)
        e.verify_assets(self.root, [record])
        for entries in ([record, record], [dict(record, name="../PicStrip.ipa")]):
            with self.assertRaises(ValueError): e.verify_assets(self.root, entries)
        file.write_bytes(b"fake ipa")
        with self.assertRaises(ValueError): e.verify_assets(self.root, [record])
        file.unlink()
        with self.assertRaises(ValueError): e.verify_assets(self.root, [record])

    def make_qa(self):
        for check in e.CHECKS:
            directory = self.root / check
            directory.mkdir()
            e.write(directory / "result.json", {"check": check, "source_sha": SHA, "status": 0})
            if check.startswith("test"):
                (directory / "report.junit").write_text('<testsuites><testsuite><testcase name="real"/></testsuite></testsuites>')
        return self.root / "test/report.junit"

    def test_qa_requires_actual_tests_and_all_checks(self):
        report = self.make_qa()
        output = self.root / "output"; output.mkdir()
        e.qa(self.root, output, SHA)
        self.assertEqual(e.read(output / "qa-manifest.json")["checks"]["test"]["executed"], 1)
        for xml in ('<testsuites/>', '<testsuite><testcase><skipped/></testcase></testsuite>', '<testsuite><testcase><failure/></testcase></testsuite>'):
            report.write_text(xml)
            with self.assertRaises(ValueError): e.qa(self.root, output, SHA)
        report.unlink()
        with self.assertRaises(FileNotFoundError): e.qa(self.root, output, SHA)

    def test_qa_rejects_another_source(self):
        self.make_qa()
        with self.assertRaises(ValueError): e.qa(self.root, self.root, "b" * 40)

    def test_safe_archive_rejects_links_traversal_and_unexpected_roots(self):
        for name, link in [("../../escape", False), ("fastlane/Fastfile", False), ("fastlane/metadata/link", True)]:
            archive = self.root / "input.tar"
            with tarfile.open(archive, "w") as tar:
                info = tarfile.TarInfo(name)
                if link: info.type = tarfile.SYMTYPE; info.linkname = "../../escape"
                else: info.size = 1
                tar.addfile(info, None if link else io.BytesIO(b"x"))
            with self.assertRaises(ValueError): e.extract(archive, self.root / "out", "fastlane/metadata")

    def test_safe_archive_extracts_only_declared_metadata(self):
        archive = self.root / "good.tar"
        with tarfile.open(archive, "w") as tar:
            info = tarfile.TarInfo("fastlane/metadata/en-US/description.txt"); info.size = 4
            tar.addfile(info, io.BytesIO(b"safe"))
        e.extract(archive, self.root / "out", "fastlane/metadata")
        self.assertEqual((self.root / "out/fastlane/metadata/en-US/description.txt").read_text(), "safe")

    def test_complete_screenshot_coverage_and_dimensions(self):
        for locale in e.CONFIG["locales"]:
            for spec in e.CONFIG["screenshot_classes"].values():
                for screen in e.CONFIG["screens"]:
                    file = self.root / locale / f"{spec['names'][0]}-{screen}.png"
                    file.parent.mkdir(exist_ok=True)
                    file.write_bytes(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", *spec["sizes"][0]))
        output = self.root / "manifest.json"
        e.screenshots(self.root, output)
        self.assertEqual(len(e.read(output)["files"]), 160)
        file.unlink()
        with self.assertRaises(ValueError): e.screenshots(self.root, output)
        file.write_text("version https://git-lfs.github.com/spec/v1")
        with self.assertRaises(ValueError): e.screenshots(self.root, output)

    def test_wrong_provenance_identity_is_rejected(self):
        statement = {"predicate": {"invocation": {"configSource": {"uri": f"git+https://github.com/{e.CONFIG['repository']}@refs/heads/main", "digest": {"sha1": SHA}, "entryPoint": ".github/workflows/main.yml"}}}}
        provenance_identity(statement, SHA)
        with self.assertRaises(ValueError): provenance_identity(statement, "b" * 40)
        statement["predicate"]["invocation"]["configSource"]["entryPoint"] = ".github/workflows/pr.yml"
        with self.assertRaises(ValueError): provenance_identity(statement, SHA)

    def test_processing_receipt_binds_exact_build_and_digest(self):
        manifest = {"version": "1.7.0", "build_number": "100.1", "source_sha": SHA, "ipa_sha256": "b" * 64}
        status = {**manifest, "app_store_build_id": "apple-build", "processing_state": "VALID"}
        e.validate_status(status, manifest)
        for key, value in [("build_number", "101.1"), ("ipa_sha256", "c" * 64), ("processing_state", "PROCESSING"), ("app_store_build_id", "")]:
            with self.assertRaises(ValueError): e.validate_status({**status, key: value}, manifest)

    def build_fixture(self):
        for name in e.REQUIRED:
            (self.root / name).write_bytes(b"fixture")
        qa = {"source_sha": SHA, "checks": {name: {"status": 0, "executed": 2, "failures": 0} for name in e.CHECKS}}
        e.write(self.root / "qa-manifest.json", qa)
        inventory = {"ipa_sha256": e.digest(self.root / "PicStrip.ipa"), "applications": [
            {"bundle_id": bundle, "version": "1.7.0", "build_number": "100.1"} for bundle in e.CONFIG["bundle_ids"]]}
        e.write(self.root / "ipa-inventory.json", inventory)
        records = [e.asset(p) for p in sorted(self.root.iterdir())]
        for producer in ("build", "package", "qa", "sbom"):
            e.write(self.root / f"{producer}-checksums.json", records)
        with patch.dict(os.environ, {"SOURCE_SHA": SHA, "VERSION": "1.7.0", "BUILD_NUMBER": "100.1", "RELEASE_RUN_ID": "900", "RELEASE_RUN_ATTEMPT": "1"}):
            e.build(self.root)
        return e.read(self.root / "release-build-manifest.json")

    def test_final_manifest_round_trip_and_substitution(self):
        manifest = self.build_fixture()
        receipt = {**{k: manifest[k] for k in ("version", "build_number", "source_sha", "ipa_sha256")},
                   "app_store_build_id": "verified-build", "processing_state": "VALID"}
        e.write(self.root / "testflight-status.json", receipt)
        (self.root / "provenance.intoto.jsonl").write_text("fixture signed separately")
        e.finalize(self.root)
        e.validate_manifest(self.root, "release-manifest.json", SHA, "v1.7.0", final=True)
        with self.assertRaises(ValueError): e.validate_manifest(self.root, "release-manifest.json", "b" * 40, final=True)
        with self.assertRaises(ValueError): e.validate_manifest(self.root, "release-manifest.json", SHA, "v1.8.0", final=True)
        receipt["app_store_build_id"] = "substituted-build"
        e.write(self.root / "testflight-status.json", receipt)
        with self.assertRaises(ValueError): e.validate_manifest(self.root, "release-manifest.json", final=True)

    def test_finalization_cannot_promote_an_unprocessed_build(self):
        manifest = self.build_fixture()
        e.write(self.root / "testflight-status.json", {**manifest, "app_store_build_id": "build", "processing_state": "PROCESSING"})
        with self.assertRaises(ValueError): e.finalize(self.root)
        self.assertFalse((self.root / "release-manifest.json").exists())

    def test_failed_signature_stops_before_manifest_is_consumed(self):
        with patch("verify_release.subprocess.run", side_effect=subprocess.CalledProcessError(1, "gh")), patch("verify_release.validate_manifest") as consume:
            with self.assertRaises(subprocess.CalledProcessError): verify(self.root, SHA, final=True)
            consume.assert_not_called()


if __name__ == "__main__": unittest.main()
