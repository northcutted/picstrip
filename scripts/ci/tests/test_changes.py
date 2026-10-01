import copy
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from changes import classify, compare, full, gate, screenshot_devices


class ChangesTests(unittest.TestCase):
    def test_matrix_cannot_omit_or_combine_devices(self):
        self.assertEqual(screenshot_devices({"screenshot_devices": ["Phone", "Pad"]}), ["Phone", "Pad"])
        for devices in [None, [], [""], [" "], ["Phone", "Phone"], ["Phone,Pad"], [None]]:
            with self.assertRaises(ValueError):
                screenshot_devices({"screenshot_devices": devices})

    def test_known_docs_only_skip_simulators(self):
        self.assertEqual(classify(["README.md", "docs/release-pipeline.md"]), dict(qa=False, screenshots=False, prepare=False, store=False))
        for paths in [[], ["docs/guide.md", "unrecognized/config"], ["docs/../PicStrip/App.swift"]]:
            self.assertEqual(classify(paths), full())

    def test_store_app_unit_tests_and_tooling_selection(self):
        for path in ["fastlane/metadata/en-US/description.txt", "fastlane/screenshots/processed/en-US/image.png"]:
            self.assertEqual(classify([path]), dict(qa=False, screenshots=False, prepare=True, store=True))
        self.assertEqual(classify(["PicStrip/ContentView.swift"]), dict(qa=True, screenshots=True, prepare=True, store=False))
        self.assertEqual(classify(["PicStripTests/MetadataTests.swift"]), dict(qa=True, screenshots=False, prepare=True, store=False))
        for path in ["scripts/ios_release.py", ".ruby-version", "fastlane/Fastfile", ".github/ios-release-platform.json", ".github/workflows/pr.yml", "scripts/helper.py"]:
            self.assertEqual(classify([path]), full())

    def test_prs_include_drafts_and_pushes_compare_exact_range(self):
        base, head = "a" * 40, "b" * 40
        for draft in [True, False]:
            def git(*args):
                self.assertEqual(args, ("diff", "--name-only", "--no-renames", "-z", f"{base}...{head}"))
                return "docs/readme.md\0PicStrip/ContentView.swift\0"
            self.assertTrue(compare("pull_request", {"pull_request": {"draft": draft, "base": {"sha": base}, "head": {"sha": head}}}, git)["qa"])
        def git(*args):
            self.assertEqual(args[-1], f"{base}..{head}")
            return "docs/readme.md\0"
        self.assertFalse(compare("push", {"before": base, "after": head}, git)["prepare"])

    def test_bad_history_manual_runs_and_renames_fail_closed(self):
        def unavailable(*args):
            raise subprocess.CalledProcessError(1, "git")
        self.assertTrue(compare("pull_request", {"pull_request": {"base": {"sha": "a" * 40}, "head": {"sha": "b" * 40}}}, unavailable)["qa"])
        for result in [compare("push", {"before": "0" * 40, "after": "a" * 40}), compare("pull_request", {}), compare("workflow_dispatch", {})]:
            for key in full():
                self.assertTrue(result[key])
        self.assertTrue(classify(["PicStrip/ContentView.swift", "docs/ContentView.swift"])["qa"])

    def test_gate_rejects_unexpected_skips_cancellation_failure_and_missing_decisions(self):
        jobs = {name: {"result": "success" if name in {"changes", "policy"} else "skipped"} for name in ["changes", "policy", "qa", "screenshots"]}
        selection = dict(qa="false", screenshots="false", store="false")
        gate(jobs, selection)
        for mutated, decisions in [({**jobs, "changes": {"result": "failure"}}, selection), (jobs, {**selection, "qa": "true"}), (jobs, {**selection, "qa": ""})]:
            with self.assertRaises(ValueError):
                gate(mutated, decisions)
        for result in ["failure", "cancelled"]:
            with self.assertRaises(ValueError):
                gate({**jobs, "policy": {"result": result}}, selection)
        gate({name: {"result": "success"} for name in jobs}, dict(qa="true", screenshots="true", store="true"))
