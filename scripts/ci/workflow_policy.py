"""PicStrip's consumer-specific workflow and release contracts."""
import json
from pathlib import Path
import re

from ios_release.yamlio import workflows as load_workflows


def validate(workflows):
    pin = json.loads(Path(".github/ios-release-platform.json").read_text())
    errors = []
    def check(value, message):
        if not value:
            errors.append(message)
    check(re.fullmatch(r"[a-f0-9]{40}", pin["revision"]), "Platform revision must be a full commit")
    for file, w in workflows.items():
        check(w.get("permissions") == {"contents": "read"}, file + ": default token must be read-only")
        check("pull_request_target" not in (w.get("on") or {}), file + ": privileged PR events forbidden")
        for name, j in w.get("jobs", {}).items():
            label = file + "/" + name
            if j.get("uses"):
                check(j["uses"].startswith(pin["repository"] + "/.github/workflows/") and j["uses"].endswith("@" + pin["revision"]), label + ": reusable workflow differs from trusted platform pin")
                check(j.get("with", {}).get("platform_revision") == pin["revision"], label + ": signer revision differs from workflow revision")
                apple = ["APP_STORE_CONNECT_API_KEY_ID", "APP_STORE_CONNECT_API_KEY_ISSUER_ID", "APP_STORE_CONNECT_API_KEY_CONTENT"]
                required = {"ci": [], "prepare": ["MATCH_PASSWORD", "MATCH_SSH_PRIVATE_KEY"], "promote": apple + ["RELEASE_APP_ID", "RELEASE_APP_PRIVATE_KEY"], "release": apple + ["RELEASE_APP_ID", "RELEASE_APP_PRIVATE_KEY"], "deploy": apple, "observe": apple}.get(j["uses"].split("/")[-1].split(".yml@")[0])
                bindings = j.get("secrets", {})
                check(required is not None and isinstance(bindings, dict) and sorted(bindings) == sorted(required) and all(bindings[key] == "${{ secrets." + key + " }}" for key in required), label + ": explicit environment secret bindings required; environment secrets must not be inherited/passed broadly")
                if file == "pr.yml":
                    check(not j.get("permissions", {}).get("id-token"), label + ": privileged PR call")
                continue
            check(type(j.get("timeout-minutes")) is int and j["timeout-minutes"] <= (240 if file == "screenshots.yml" else 90), label + ": bounded timeout required")
            scripts = "\n".join(s.get("run", "") for s in j.get("steps", []))
            check(not re.search(r"\$\{\{\s*(inputs\.|github\.event\.)", scripts), label + ": unsafe input interpolation")
            for s in j.get("steps", []):
                uses = s.get("uses", "")
                if not uses:
                    continue
                check(re.search(r"@[a-f0-9]{40}$", uses), label + ": action must be pinned by SHA")
                if uses.startswith("actions/checkout@"):
                    check(s.get("with", {}).get("persist-credentials") is False, label + ": persisted checkout credentials")
                if uses.startswith(pin["repository"] + "/"):
                    check(uses.endswith("@" + pin["revision"]), label + ": platform action revision drift")
            if file == "pr.yml":
                check("secrets." not in json.dumps(j) and not j.get("environment") and not j.get("permissions", {}).get("id-token"), label + ": PR path must not receive secrets")
            check(not re.search(r"fastlane (request_review|app_store_stage|metadata_only|upload_testflight)|publish_release\.py", scripts), label + ": release administration belongs in pinned platform")
    pr, main, promote, deploy = (workflows[name]["jobs"] for name in ["pr.yml", "main.yml", "promote.yml", "app-store-deploy.yml"])
    check("gems-macos" not in pr, "Platform and screenshot checks own Ruby dependency validation")
    smoke = pr["screenshots"]
    strategy = smoke.get("strategy", {})
    check(strategy.get("matrix", {}).get("device") == "${{ fromJSON(needs.changes.outputs.screenshot_devices) }}" and strategy.get("fail-fast") is False, "Every configured screenshot device must run on a separate host and retain its result")
    check(any(step.get("env", {}).get("SCREENSHOT_DEVICE") == "${{ matrix.device }}" and '--devices "$SCREENSHOT_DEVICE"' in step.get("run", "") for step in smoke["steps"]), "Screenshot capture must select exactly its matrix device")
    for file in ["pr.yml", "screenshots.yml"]:
        check(not re.search(r"bundle (install|exec fastlane)", json.dumps(workflows[file])), "Screenshot tools must use the supported platform command and locked Ruby action")
    check("/prepare.yml@" in main["prepare"]["uses"], "Main must only prepare candidates")
    check(sorted(main) == ["changes", "prepare"], "Main may only classify changes and prepare candidates")
    check(main["prepare"].get("if") == "needs.changes.outputs.prepare == 'true'", "Preparation must honor classified release inputs")
    check(not any(type in {"labeled", "unlabeled"} for type in workflows["pr.yml"]["on"]["pull_request"]["types"]), "Unrelated labels must not restart PR checks")
    check("changes" in pr["gate"]["needs"], "CI Gate must require classification")
    for job in ["qa", "screenshots"]:
        check(pr[job].get("if") == f"needs.changes.outputs.{job} == 'true'", job + ": must honor conservative classification")
    check("workflow_dispatch" in workflows["promote.yml"]["on"] and "push" not in workflows["promote.yml"]["on"], "Promotion must be explicit")
    check(pr["gate"].get("name") == "CI Gate" and pr["gate"].get("if") == "always()", "CI Gate must always report")
    check("published" in workflows["app-store-deploy.yml"]["on"]["release"]["types"], "Deploy must consume published release")
    check("/release.yml@" in promote["promote"]["uses"], "Release must use the verified selection interface")
    check(workflows["promote.yml"]["on"]["workflow_dispatch"]["inputs"]["source"].get("required"), "Release must identify an explicit source")
    check(deploy["deploy"]["with"].get("metadata_commit") == "${{ needs.resolve.outputs.metadata_commit }}", "Metadata updates must preserve the resolved exact commit")
    return errors


if __name__ == "__main__":
    errors = validate(load_workflows(".github/workflows"))
    if errors:
        raise SystemExit("\n".join(errors))
    print("Consumer workflow policy passed.")
