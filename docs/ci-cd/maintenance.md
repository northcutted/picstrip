# Maintain the pipeline and its docs

[Start here](../release-pipeline.md) · [Operations](operations.md) · [Architecture](architecture.md) · [Reference](reference.md)

Keep **intent in prose, facts in source, and current state in service readback**. The reference is generated locally from checked-in files; there is no documentation service, network lookup, credential requirement, or second workflow catalog to maintain.

## Quick edit loop

Use Node 24 (the CI runtime) and run these from the repository root:

```sh
npm ci --ignore-scripts
make docs
make check-docs
npm run check:workflows
npm run test:ci
actionlint
git diff --check
```

`make docs` updates [reference.md](reference.md) and [reference.json](reference.json). `make check-docs` is read-only: it fails on stale output or broken local file/heading links in the maintained CI/CD pages. It runs in the mandatory PR policy job, including documentation-only PRs. Existing CI tests include the generator's failure and regeneration cases.

After changing only prose, no generated output should change. After changing workflow/configuration facts, run `make docs` and commit the source and generated diff together. For iOS/behavior changes, run their appropriate checks too; documentation validation does not replace app tests or live control verification.

## Where to edit

| Change | Edit | Then |
| --- | --- | --- |
| Operator guidance or rationale | The relevant handwritten page here | Check links and review the explanation |
| Workflow event, input, job, or dependency | `.github/workflows/*.yml` | Regenerate and review the workflow policy tests |
| App/toolchain/store configuration | `.github/ios-release.json` | Regenerate; validate affected build/store behavior |
| Shared release behavior | The platform repository | Run platform checks, review its commit, then update the app pin |
| Platform adoption | `python3 scripts/update_release_platform.py FULL_REVIEWED_PLATFORM_SHA` | Regenerate, review all pins/producer approvals, run CI |
| Check selection | `scripts/ci/changes.mjs` and its tests | Regenerate examples; retain conservative fallback and the always-reporting gate |
| Reference format or extracted fields | `scripts/ci/docs.mjs` and its tests | Regenerate; review machine consumers if schema changes |
| Run results or release acceptance | A dated record under `docs/reviews/` or `docs/evidence/` | Link exact runs/commits; label the observation time |

Do not hand-edit generated output, paste changing SHAs/toolchain versions into prose, or copy reusable platform implementation into PicStrip. A new workflow is discovered automatically, but its **purpose and side effects** still need human-readable guidance. Full history/evidence does not belong in the quick-start guide.

## Agent reading and editing recipe

1. Read [the start page](../release-pipeline.md) and this recipe for orientation.
2. Query the JSON index for the task, rather than loading every workflow and historical report:

   ```sh
   jq '.workflows[] | {file, name, inputs}' docs/ci-cd/reference.json
   jq '.workflows[] | select(.file | endswith("promote.yml"))' docs/ci-cd/reference.json
   jq '{platform, configuration: .configuration | {xcode, compatibility, replacement_release}}' docs/ci-cd/reference.json
   ```

3. Inspect the relevant authoritative source file and, for shared behavior, the pinned platform implementation. The index omits step scripts and reusable internals; it is a navigation aid, not release evidence.
4. Make the smallest source/prose change, regenerate, and run the quick edit loop. Keep release authorization, exact-build selection, and production approval intact.
5. Report what changed and which checks ran. Keep immutable identities and observed status distinct. A docs PR is not permission to upload, publish, submit, refresh control baselines, or change live credentials.

The JSON has a `schema_version`, source paths, platform identity, selected configuration, executable classifier examples, and consumer workflow interfaces/job dependencies. `null` fields mean no explicit value at that consumer layer. Changes to existing field meaning require a schema version bump; additive fields can retain the version.

## How generation stays cheap

The [generator](../../scripts/ci/docs.mjs) uses Node built-ins, the already locked `yaml` dependency, and the real change classifier. It discovers `.yml` and `.yaml` workflow files, sorts filenames, and emits deterministic output without timestamps, run IDs, network calls, or source hashes that change for comment-only edits.

Only relevant public configuration and consumer job interfaces enter the index; raw shell scripts and secret values are omitted. It links reusable workflows at the pinned commit instead of downloading them. This keeps diffs and agent context small while preserving a clear source trail.

Link validation discovers Markdown pages in `docs/ci-cd/` plus the start page. It checks their simple inline relative links and heading anchors; it does not crawl external URLs, validate all historical evidence, or execute documented commands. Use simple unique headings and inline links in these pages. The generated references and link checks run together so a stale index cannot silently pass.

## Inspect or change repository controls

Use **Release Maintenance → Inspect release controls** on main for read-only REST/GraphQL inspection. This uses the existing release-publishing environment, emits no credentials, and changes neither GitHub nor Apple state.

The publisher token retains Administration: read. Because GitHub can redact bypass actors, `.github/ios-release.json` records an owner-verified `github_controls` baseline: publisher App, ruleset IDs, server timestamps, and GraphQL bypass-node identities. Preflight requires unchanged, complete evidence. The supported redacted case is exactly one owner-recorded Integration, `[null]` nodes, no next page, unchanged server identity/time, and the token's effective `always` bypass. Empty, changed, or conflicting evidence is rejected.

For an intended ruleset change, inspect as owner and review a baseline refresh using the pinned platform's `scripts/ci/capture_controls.py`. Release jobs must never refresh their own trust baseline automatically.

The repository setup helper first requires successful CI for the exact checked-out revision. Preview before applying; application changes controls and disables distribution while preserving production reviewers:

```sh
python3 scripts/ci/configure_repository.py --ci-run CI_RUN_ID --release-app-id REVIEWED_APP_ID
# Apply only as an intentional, authorized control change:
python3 scripts/ci/configure_repository.py --ci-run CI_RUN_ID --release-app-id REVIEWED_APP_ID --apply
```

Read back the resulting rules/environments and complete a signed rehearsal before re-enabling distribution. These are setup/repair operations, not steps required for every release.
