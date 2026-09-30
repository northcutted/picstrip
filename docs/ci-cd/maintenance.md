# Maintain PicStrip's integration

[Start here](../release-pipeline.md) · [Operations](operations.md) · [Architecture](architecture.md) · [Reference](reference.md)

Keep app policy and operating instructions here. Change reusable code, dependency locks, architecture, recovery guidance and documentation generation in the Actions repository. The [platform guides](reference.md#platform-guides) are linked at the revision PicStrip uses.

## Quick edit loop

```sh
npm ci --ignore-scripts
make platform-sync
make docs
make check-docs
npm run check:workflows
npm run test:ci
actionlint
```

`platform-sync` fetches the reviewed commit once into ignored `build/ios-release-platform/`; subsequent documentation commands are offline. The cached checkout must remain clean and at the exact pin. CI already has the pinned platform from its bootstrap Action. `make docs` writes the local Markdown/JSON reference. `make check-docs` rejects drift and broken maintained local links without writing files.

For local analysis/tests, use `make analyze` and `make test` with the configured Xcode builds installed. They require no Fastlane. For screenshots or local archives, use the Ruby version in [.ruby-version](../../.ruby-version), run `make platform-gems`, then `make screenshots` or `make build MARKETING_VERSION=X.Y.Z BUILD_NUMBER=N.ATTEMPT`. Archive output is `build/application.ipa`; local builds do not constitute authenticated release candidates.

## Where to edit

| Change | Source | Verification |
| --- | --- | --- |
| App identity/toolchains/store policy | `.github/ios-release.json` | Regenerate; check affected native/store behavior |
| Entry events or manual inputs | `.github/workflows/` | Regenerate; workflow policy and CI |
| Which changes select checks | `scripts/ci/changes.mjs` | Classifier/gate tests; regenerate examples |
| Doc example paths or page navigation | `.github/ios-release-docs.json` | `make docs` and `make check-docs` |
| App operating instructions | The relevant page here | Check links and commands |
| Shared tools, dependency locks or generator | Actions repository | Platform checks and a consumer run before adopting |
| Platform adoption | `python3 scripts/update_release_platform.py FULL_REVIEWED_SHA` | Sync, regenerate and review pins/producer approvals; full CI |

The [launcher](../../scripts/ios_release.py) forwards to the supported platform CLI. Use its `toolchain`, `controls-configure` and `benchmark` subcommands directly. Do not restore a separate app Ruby lockfile or copy platform code here.

## Agent reading and editing recipe

1. Read the [start page](../release-pipeline.md), then query the generated index for the task:

   ```sh
   jq '.workflows[] | {file, name, inputs}' docs/ci-cd/reference.json
   jq '.workflows[] | select(.file | endswith("promote.yml"))' docs/ci-cd/reference.json
   jq '{platform, configuration: .configuration | {xcode, compatibility, replacement_release}}' docs/ci-cd/reference.json
   ```

2. Read the relevant authoritative app source and pinned platform guide. Generated output records declared contracts, not live release status.
3. Edit the correct repository, regenerate and run appropriate checks. Prose-only edits should not churn generated facts.
4. Report changes and local/hosted results separately. Preserve the exact accepted binary and production approval.

For deliberate platform development, `IOS_RELEASE_ROOT=/path/to/trusted/platform` overrides the cache. This is a trusted local override, not a release input. Check normal operation against the committed pin before delivery.

## Inspect or change repository controls

Use **Release Maintenance → Inspect release controls** for read-only live inspection. Shared control-baseline capture, setup and recovery procedures are in the [pinned maintenance guide](reference.md#platform-guides). Baselines require owner readback and review; release jobs cannot refresh their own authority.

Run `python3 scripts/ios_release.py controls-configure --help` for the supported setup interface. Its default previews changes; `--apply` intentionally changes live controls. Setup/repair is separate from normal releases.
