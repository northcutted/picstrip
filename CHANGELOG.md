## [1.3.0](https://github.com/northcutted/picstrip/compare/v1.2.4...v1.3.0) (2026-05-08)


### Features

* Add support for handling alpha channel in PNG metadata ([c1f361a](https://github.com/northcutted/picstrip/commit/c1f361a0738547283abff54fad4a23e55d633c28))


### Bug Fixes

* harden unit tests, rename Fastfile lane, refresh screenshots ([b177ffa](https://github.com/northcutted/picstrip/commit/b177ffa4a7f5f7216acbda774bcd5b2b030d22fa))
* replace fixed sleep with polling wait in testFocusPIIResult ([94a010e](https://github.com/northcutted/picstrip/commit/94a010ee865ed98f7b9c24642a567326ea29befc))

## [1.2.4](https://github.com/northcutted/picstrip/compare/v1.2.3...v1.2.4) (2026-05-07)


### Bug Fixes

* **ci:** convert inline python3 -c to heredocs in screenshots.yml ([04853fc](https://github.com/northcutted/picstrip/commit/04853fc421121b504e9454277dcd4a11317b06b6))
* **ci:** remove duplicate contents: key from pr.yml permissions block ([6af7227](https://github.com/northcutted/picstrip/commit/6af7227a758fe85a7a8906f5de133cd2edb47ca6))
* finalize submission ([1b2582e](https://github.com/northcutted/picstrip/commit/1b2582eda0de615ee003bfc98555f2898c610459))
* rename step id from 'inputs' to 'hash' to avoid reserved context conflict ([218a585](https://github.com/northcutted/picstrip/commit/218a5855f689f3a9a73206dd037ed515b0efab5b))
* replace <br/> with \n in Mermaid graph TD node labels ([8ce2e3c](https://github.com/northcutted/picstrip/commit/8ce2e3cad94f98ce15a41eb9fe9f299fef67e706))
* simplify screenshots workflow to a single manual upload job ([ef78e25](https://github.com/northcutted/picstrip/commit/ef78e2535cd22868516224318dfd9324bb874a0b))
* upload job reads screenshots from checkout, not artifact download ([84b53d5](https://github.com/northcutted/picstrip/commit/84b53d5a1de14430478057411735aea5d66f978e))
* use shell find for screenshot validation + add upload job diagnostics ([8595a0a](https://github.com/northcutted/picstrip/commit/8595a0a8e4be1f5da473f6ef700829fd87d6b94b))


### Documentation

* add app icon and framed screenshots to README ([1da4aec](https://github.com/northcutted/picstrip/commit/1da4aec92667ab37f63ca7fc51c4460c5b0ebe65))
* apply app brand palette to all Mermaid diagrams ([ed0bae3](https://github.com/northcutted/picstrip/commit/ed0bae38066715fb6e71c5d5e51e7d3110a0d746))
* correct CI/CD pipeline description to match actual workflow files ([4343c5b](https://github.com/northcutted/picstrip/commit/4343c5b7ecdbb2f6add6baaa13082ec41d7d14aa))
* replace ASCII pipeline diagram with Mermaid flowchart ([1d028f1](https://github.com/northcutted/picstrip/commit/1d028f12b515bd8ae3c18df95955d5ed747dbf26))
* update CI badge to point to the correct workflow file ([19085f5](https://github.com/northcutted/picstrip/commit/19085f53a0ccf3420c4c313789118e863a4a1a95))
* use rendered icon from Icon Composer as README logo, centered ([9c2ecac](https://github.com/northcutted/picstrip/commit/9c2ecacce4c1785d7a6b64cf59295dc09843cc68))

## [1.2.3](https://github.com/northcutted/picstrip/compare/v1.2.2...v1.2.3) (2026-05-06)


### Bug Fixes

* fix pipeline ([41a573b](https://github.com/northcutted/picstrip/commit/41a573b67546c99f804910dfc6ee65650438ba40))

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
