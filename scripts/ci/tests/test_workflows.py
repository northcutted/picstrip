from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from workflow_policy import load_workflows, validate


class WorkflowTests(unittest.TestCase):
    def workflows(self):
        return load_workflows(".github/workflows")

    def test_pin_and_approval_boundaries(self):
        self.assertEqual(validate(self.workflows()), [])

    def test_mutable_calls_inherited_secrets_and_missing_bindings(self):
        w = self.workflows()
        main = w["main.yml"]["jobs"]["prepare"]
        main["uses"] = main["uses"].rsplit("@", 1)[0] + "@main"
        main["secrets"] = "inherit"
        errors = "\n".join(validate(w))
        self.assertIn("trusted platform pin", errors)
        self.assertIn("environment secrets", errors)
        w = self.workflows()
        del w["main.yml"]["jobs"]["prepare"]["secrets"]["MATCH_SSH_PRIVATE_KEY"]
        self.assertIn("explicit environment secret bindings", "\n".join(validate(w)))

    def test_pr_secrets_interpolation_and_automatic_promotion(self):
        w = self.workflows()
        w["pr.yml"]["jobs"]["policy"]["steps"].append({"run": "echo ${{ inputs.untrusted }}", "env": {"KEY": "${{ secrets.KEY }}"}})
        w["promote.yml"]["on"]["push"] = {}
        errors = "\n".join(validate(w))
        for text in ["PR path", "unsafe input", "explicit"]:
            self.assertIn(text, errors)

    def test_label_restarts_and_missing_classification(self):
        w = self.workflows()
        w["pr.yml"]["on"]["pull_request"]["types"].append("labeled")
        w["pr.yml"]["jobs"]["gate"]["needs"].remove("changes")
        errors = "\n".join(validate(w))
        self.assertIn("labels", errors)
        self.assertIn("require classification", errors)

    def test_explicit_release_selection_and_metadata_forwarding(self):
        w = self.workflows()
        w["promote.yml"]["on"]["workflow_dispatch"]["inputs"]["source"]["required"] = False
        w["app-store-deploy.yml"]["jobs"]["deploy"]["with"]["metadata_commit"] = "main"
        errors = "\n".join(validate(w))
        self.assertIn("explicit source", errors)
        self.assertIn("resolved exact commit", errors)

    def test_ruby_installs_and_device_omission_are_rejected(self):
        w = self.workflows()
        smoke = w["pr.yml"]["jobs"]["screenshots"]
        smoke["steps"].append({"run": "bundle install"})
        smoke["strategy"]["matrix"]["device"] = ["Only one device"]
        for step in smoke["steps"]:
            step.get("env", {}).pop("SCREENSHOT_DEVICE", None)
        errors = "\n".join(validate(w))
        for text in ["supported platform command", "Every configured screenshot device", "exactly its matrix device"]:
            self.assertIn(text, errors)
