#!/usr/bin/env python3
"""Preview/apply repository controls only after this revision's CI Gate has passed."""
import argparse
import json
from pathlib import Path
import subprocess

CONFIG = json.loads((Path(__file__).resolve().parents[2] / ".github/ios-release.json").read_text())

def require(condition, message):
    if not condition: raise ValueError(message)


def api(path, method="GET", payload=None):
    command = ["gh", "api", path, "--method", method]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.check_output(command, input=json.dumps(payload) if payload is not None else None, text=True)
    return json.loads(result) if result.strip() else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ci-run", required=True, type=int)
    parser.add_argument("--release-app-id", required=True, type=int)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    repository = CONFIG["repository"]
    prefix = f"repos/{repository}"
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    run = api(f"{prefix}/actions/runs/{args.ci_run}")
    require(run["head_sha"] == sha and run["name"] == "PR Checks" and run["conclusion"] == "success", "CI must pass for the current checked-in revision")
    jobs = api(f"{prefix}/actions/runs/{args.ci_run}/jobs?per_page=100")["jobs"]
    require(any(job["name"] == "CI Gate" and job["conclusion"] == "success" for job in jobs), "CI Gate has not passed")
    require(args.release_app_id > 0, "Release App ID must be positive")
    existing_envs = {e["name"]: e for e in api(f"{prefix}/environments")["environments"]}
    require("production" in existing_envs, "Existing production approval must be configured first")
    require(any(p["type"] == "required_reviewers" and p.get("reviewers")
                for p in existing_envs["production"].get("protection_rules", [])),
            "Production must retain required approval")
    main_rules = {"name": "Main", "target": "branch", "enforcement": "active", "bypass_actors": [],
                  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
                  "rules": [{"type": "deletion"}, {"type": "non_fast_forward"},
                            {"type": "pull_request", "parameters": {"required_approving_review_count": 0,
                             "dismiss_stale_reviews_on_push": True, "require_code_owner_review": False,
                             "require_last_push_approval": False, "required_review_thread_resolution": True}},
                            {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": True,
                             "required_status_checks": [{"context": "CI Gate", "integration_id": 15368}]}}]}
    tag_rules = {"name": "Release tags", "target": "tag", "enforcement": "active",
                 "bypass_actors": [{"actor_id": args.release_app_id, "actor_type": "Integration", "bypass_mode": "always"}],
                 "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
                 "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}]}
    environments = {"signing": ("branch", "main"), "testflight": ("branch", "main"),
                    "release-publishing": ("branch", "main"), "screenshot-publishing": ("branch", "main"),
                    "app-store-staging": ("tag", "v*"), "production": ("tag", "v*"),
                    "app-store-observe": ("branch", "main")}
    print(json.dumps({"verified_sha": sha, "rulesets": [main_rules, tag_rules], "environment_refs": environments,
                      "immutable_releases": True, "dependabot_security_updates": True,
                      "RELEASE_DISTRIBUTION_ENABLED": "false"}, indent=2))
    if not args.apply:
        return
    # Keep distribution off throughout rollout; do not overwrite approval reviewers.
    variables = api(f"{prefix}/actions/variables")["variables"]
    var = {"name": "RELEASE_DISTRIBUTION_ENABLED", "value": "false"}
    if any(v["name"] == var["name"] for v in variables):
        api(f"{prefix}/actions/variables/{var['name']}", "PATCH", var)
    else:
        api(f"{prefix}/actions/variables", "POST", var)
    rules = api(f"{prefix}/rulesets")
    for rule in [main_rules, tag_rules]:
        existing = next((r for r in rules if r["name"] == rule["name"]), None)
        api(f"{prefix}/rulesets" + (f"/{existing['id']}" if existing else ""), "PUT" if existing else "POST", rule)
    for name, (kind, ref) in environments.items():
        old = existing_envs.get(name, {})
        protections = old.get("protection_rules", [])
        reviewers = next((r for r in protections if r["type"] == "required_reviewers"), {})
        if name == "production": require(reviewers.get("reviewers"), "Production must retain required approval")
        payload = {"deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
                   "can_admins_bypass": False}
        if reviewers:
            payload.update(prevent_self_review=reviewers.get("prevent_self_review", False),
                           reviewers=[{"type": r["type"], "id": r["reviewer"]["id"]} for r in reviewers["reviewers"]])
        timer = next((r for r in protections if r["type"] == "wait_timer"), None)
        if timer: payload["wait_timer"] = timer["wait_timer"]
        api(f"{prefix}/environments/{name}", "PUT", payload)
        policies = api(f"{prefix}/environments/{name}/deployment-branch-policies")["branch_policies"]
        for policy in policies:
            if policy["name"] != ref or policy["type"] != kind:
                api(f"{prefix}/environments/{name}/deployment-branch-policies/{policy['id']}", "DELETE")
        if not any(p["name"] == ref and p["type"] == kind for p in policies):
            api(f"{prefix}/environments/{name}/deployment-branch-policies", "POST", {"name": ref, "type": kind})
    api(f"{prefix}/immutable-releases", "PUT")
    api(f"{prefix}/vulnerability-alerts", "PUT")
    api(f"{prefix}/automated-security-fixes", "PUT")
    require(api(f"{prefix}/immutable-releases")["enabled"], "Immutable releases did not enable")
    actual_rules = {r["name"]: api(f"{prefix}/rulesets/{r['id']}") for r in api(f"{prefix}/rulesets")}
    for wanted in [main_rules, tag_rules]:
        actual = actual_rules[wanted["name"]]
        for field in ("target", "enforcement", "conditions", "bypass_actors"):
            require(actual[field] == wanted[field], f"Ruleset readback differs: {wanted['name']} {field}")
        actual_types = {rule["type"]: rule for rule in actual["rules"]}
        require(set(actual_types) == {rule["type"] for rule in wanted["rules"]}, "Ruleset control types differ")
        for rule in wanted["rules"]:
            parameters = actual_types[rule["type"]].get("parameters", {})
            for key, value in rule.get("parameters", {}).items():
                require(parameters.get(key) == value, f"Rule parameter differs: {rule['type']} {key}")
    for name, (kind, ref) in environments.items():
        actual = api(f"{prefix}/environments/{name}")
        require(actual.get("can_admins_bypass") is False, f"Environment bypass remains enabled: {name}")
        policies = api(f"{prefix}/environments/{name}/deployment-branch-policies")["branch_policies"]
        require([(p["name"], p["type"]) for p in policies] == [(ref, kind)], f"Environment refs differ: {name}")
        if name == "production":
            require(any(p["type"] == "required_reviewers" and p.get("reviewers") for p in actual["protection_rules"]), "Production approval missing after apply")
    print("Repository controls applied and read back; distribution remains disabled pending a verified candidate.")


if __name__ == "__main__": main()
