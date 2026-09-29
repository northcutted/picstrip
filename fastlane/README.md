# Screenshot scenarios

PicStrip's Fastfile contains app-specific screenshot capture only. Run `make platform-sync`, `make platform-gems`, then `make screenshots`. `make process-screenshots` calls the Python compositor directly.

The pinned platform owns Ruby dependencies, native QA, signing, archive/export and release operations. Use `make lint`, `make analyze`, `make test` and `make build` for local commands. Old local release-administration lane names remain disabled.

See [PicStrip operations](../docs/release-pipeline.md) and the [integration guide](../docs/ci-cd/maintenance.md).
