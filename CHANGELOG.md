## [1.2.2](https://github.com/northcutted/picstrip/compare/v1.2.1...v1.2.2) (2026-05-06)


### Bug Fixes

* add timeout to screenshot job to avoid burning actions mins ([5ff7a5c](https://github.com/northcutted/picstrip/commit/5ff7a5c3ae7f638c76c4aa0f53ae7ee7f2f5dae6))
* testing ci pipeline changes ([fe2f526](https://github.com/northcutted/picstrip/commit/fe2f5263bd023596b5c36bbabab2f40b342b8f69))

## [1.2.1](https://github.com/northcutted/picstrip/compare/v1.2.0...v1.2.1) (2026-05-06)


### Bug Fixes

* dummy edit from mobile to trigger release ([a8d1ec0](https://github.com/northcutted/picstrip/commit/a8d1ec0604394a820b802ae7d3ec5624227898a7))

## [1.2.0](https://github.com/northcutted/picstrip/compare/v1.1.3...v1.2.0) (2026-05-06)


### Features

* Refactor image processing and metadata handling ([60eab86](https://github.com/northcutted/picstrip/commit/60eab8683685f8ea8cec3f47614af63179731be4))


### Bug Fixes

* Add write permissions for semantic-release in version job ([d555a82](https://github.com/northcutted/picstrip/commit/d555a8286fc4c87b5c6e110fd9441827f6efbb0d))
* Update SwiftLint configuration and improve lint lane command ([01ae1e0](https://github.com/northcutted/picstrip/commit/01ae1e09ebe2a7637c7682f1dec0dcf0c1fa7ae4))

## [1.1.3](https://github.com/northcutted/picstrip/compare/v1.1.2...v1.1.3) (2026-05-05)


### Bug Fixes

* Update iPad Pro device references to M5 in screenshot configurations ([b5a5e9e](https://github.com/northcutted/picstrip/commit/b5a5e9ebfe62420f67b5425a0e2f7a5295a79ad0))

## [1.1.2](https://github.com/northcutted/picstrip/compare/v1.1.1...v1.1.2) (2026-05-05)


### Bug Fixes

* Add UITests to TestAction in scheme configuration ([e1c1da5](https://github.com/northcutted/picstrip/commit/e1c1da57106432887df6fa07f5f2c77789ed2b4c))

## [1.1.1](https://github.com/northcutted/picstrip/compare/v1.1.0...v1.1.1) (2026-05-05)


### Bug Fixes

* Enhance accessibility and improve user experience ([fb4891c](https://github.com/northcutted/picstrip/commit/fb4891cdc005c5ed9db7e7de9d1565a359118ed1))
* fix ci pipeline and trigger new release ([e6a3ca0](https://github.com/northcutted/picstrip/commit/e6a3ca0bd17013a653ba73246aab7a09f0116df8))
* trigger new release ([299fdcd](https://github.com/northcutted/picstrip/commit/299fdcd3e03533c9e6448ed77294ae9844884da8))
* Update fastlane dependency version and add checksums for all dependencies ([ffad3e0](https://github.com/northcutted/picstrip/commit/ffad3e08c4ae1064bc4954630d94168983bb8c35))

## [1.1.0](https://github.com/northcutted/picstrip/compare/v1.0.4...v1.1.0) (2026-05-04)


### Features

* add detection pipeline ([19c1611](https://github.com/northcutted/picstrip/commit/19c16118671d91943fe5e59d60e2ade6841691b6))

## [1.0.4](https://github.com/northcutted/picstrip/compare/v1.0.3...v1.0.4) (2026-05-03)


### Bug Fixes

* correct for SLSA generator workflow reference ([625e923](https://github.com/northcutted/picstrip/commit/625e923557bcb1ab6fca3d659bd72602fb11d77a))

## [1.0.3](https://github.com/northcutted/picstrip/compare/v1.0.2...v1.0.3) (2026-05-03)


### Bug Fixes

* update action versions and add caching for SwiftLint in PR workflow ([37b41ce](https://github.com/northcutted/picstrip/commit/37b41ceb2b1b11e8d2c04d94f82ea653693a161f))

## [1.0.2](https://github.com/northcutted/picstrip/compare/v1.0.1...v1.0.2) (2026-05-03)


### Bug Fixes

* update IPA hash output format for SLSA compatibility ([78e7069](https://github.com/northcutted/picstrip/commit/78e7069f164a9b9a406a283f4a2e7f50e4758998))

## [1.0.1](https://github.com/northcutted/picstrip/compare/v1.0.0...v1.0.1) (2026-05-03)


### Bug Fixes

* switch to macos-26 runner for iOS 26 SDK requirement ([61f175e](https://github.com/northcutted/picstrip/commit/61f175ea417f1a74797079bb1f021941da718a31))

## 1.0.0 (2026-05-03)


### Features

* initial PicStrip app release ([eb5d255](https://github.com/northcutted/picstrip/commit/eb5d2553e867bc819ef835ee2226d53391f5dba4))


### Bug Fixes

* capture semantic-release outputs for downstream jobs ([fdb622e](https://github.com/northcutted/picstrip/commit/fdb622eaa74a8c1aa21f4b894db096a8d23af824))
* create temporary keychain on CI to prevent signing prompt hang ([f6f76f5](https://github.com/northcutted/picstrip/commit/f6f76f5d71289afce235144e4ebbca8f3618f11f))
* remove api_key_path from Matchfile, use env vars on CI ([3d96491](https://github.com/northcutted/picstrip/commit/3d96491d99e96b99a209256681be7c55eac00a07))
* set manual signing for Release config, remove xcargs workaround ([633023c](https://github.com/northcutted/picstrip/commit/633023c2b1877694c5c050df1f14edbd55e677b1))

## 1.0.0 (2026-05-03)


### Features

* initial PicStrip app release ([eb5d255](https://github.com/northcutted/picstrip/commit/eb5d2553e867bc819ef835ee2226d53391f5dba4))


### Bug Fixes

* capture semantic-release outputs for downstream jobs ([fdb622e](https://github.com/northcutted/picstrip/commit/fdb622eaa74a8c1aa21f4b894db096a8d23af824))
* remove api_key_path from Matchfile, use env vars on CI ([3d96491](https://github.com/northcutted/picstrip/commit/3d96491d99e96b99a209256681be7c55eac00a07))
* set manual signing for Release config, remove xcargs workaround ([633023c](https://github.com/northcutted/picstrip/commit/633023c2b1877694c5c050df1f14edbd55e677b1))

## 1.0.0 (2026-05-03)


### Features

* initial PicStrip app release ([eb5d255](https://github.com/northcutted/picstrip/commit/eb5d2553e867bc819ef835ee2226d53391f5dba4))


### Bug Fixes

* capture semantic-release outputs for downstream jobs ([fdb622e](https://github.com/northcutted/picstrip/commit/fdb622eaa74a8c1aa21f4b894db096a8d23af824))
* remove api_key_path from Matchfile, use env vars on CI ([3d96491](https://github.com/northcutted/picstrip/commit/3d96491d99e96b99a209256681be7c55eac00a07))

## 1.0.0 (2026-05-03)


### Features

* initial PicStrip app release ([eb5d255](https://github.com/northcutted/picstrip/commit/eb5d2553e867bc819ef835ee2226d53391f5dba4))


### Bug Fixes

* capture semantic-release outputs for downstream jobs ([fdb622e](https://github.com/northcutted/picstrip/commit/fdb622eaa74a8c1aa21f4b894db096a8d23af824))

## 1.0.0 (2026-05-03)


### Features

* initial PicStrip app release ([eb5d255](https://github.com/northcutted/picstrip/commit/eb5d2553e867bc819ef835ee2226d53391f5dba4))
