# PicStrip

[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](https://www.apple.com/ios/)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![GitHub Actions](https://github.com/northcutt-dev/picstrip/actions/workflows/pr.yml/badge.svg)](https://github.com/northcutt-dev/picstrip/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Your photos, your privacy. Strip metadata and redact sensitive information—100% on your device.**

PicStrip is a privacy-focused photo scrubber that removes EXIF location data, metadata, and visually redacts personally identifiable information (PII) from images before you share them. Everything happens on-device with zero network connectivity required.

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| **Metadata Stripping** | Removes GPS, EXIF, TIFF, IPTC, and Apple Maker Note metadata in a single tap |
| **Visual PII Detection** | On-device OCR scans image content for emails, phone numbers, SSNs, API keys, passwords, and 15+ other sensitive data types |
| **Visual PII Redaction** | Automatically burns opaque redaction boxes over detected sensitive regions |
| **Batch Processing** | Clean multiple photos at once with a uniform privacy policy |
| **Replace Original** | Securely replace the original photo in your library with the cleaned version |
| **Flexible Export** | Save as PNG (max privacy), JPEG, HEIC, or original format with adjustable compression |
| **Per-Field Control** | Fine-grained toggles for individual metadata fields and PII detection types |
| **Audit Reports** | Export a detailed JSON audit showing exactly what was stripped and redacted |
| **Share Extension** | Clean photos directly from the iOS share sheet without leaving your current app |
| **Siri Shortcuts** | "Clean Photos with PicStrip" intent integrates with Shortcuts and Spotlight |

---

## 🛠 Tech Stack

| Component | Framework | Version | Purpose |
|-----------|-----------|---------|---------|
| **UI Framework** | SwiftUI | iOS 17+ | Native, declarative user interface |
| **Data Layer** | Swift `@Observable` | 5.9+ | Lightweight state management (MVVM) |
| **OCR Engine** | Vision framework | iOS 17+ | On-device text recognition |
| **Metadata Processing** | ImageIO | iOS 17+ | EXIF, TIFF, IPTC extraction and stripping |
| **Photo Library Access** | Photos, PhotosUI | iOS 17+ | Photo picking and saving |
| **App Intents** | AppIntents | iOS 17+ | Siri Shortcuts and Spotlight integration |
| **Image Rendering** | UIGraphicsImageRenderer | iOS 17+ | Redaction box rendering |
| **CI/CD** | GitHub Actions, Fastlane | Latest | Automated testing, builds, and releases |

**Zero third-party dependencies.** PicStrip uses only Apple frameworks, ensuring maximum privacy and minimum bloat.

---

## 📋 Requirements

- **Xcode:** 15.0 or later
- **iOS:** 17.0 or later
- **macOS:** 13.0 or later (for development)
- **Apple Developer Account:** Required to sign the app and Share Extension

---

## 🚀 Getting Started

### Clone and Open

```bash
git clone https://github.com/northcutt-dev/picstrip.git
cd PicStrip
open PicStrip.xcodeproj
```

### Select Signing Team

1. Open `PicStrip.xcodeproj` in Xcode
2. Select the **PicStrip** target
3. Go to **Signing & Capabilities**
4. Change the **Team** dropdown to your Apple Developer Team
5. Repeat for the **PicStripShareExtension** target

### Run on Device or Simulator

1. Select a target device (iPhone 15+ simulator or physical device running iOS 17+)
2. Press **Cmd + R** to build and run
3. The app will launch on the home screen with an animated gradient and "PicStrip" title

### Build for Release

```bash
fastlane build
```

This signs the app with App Store distribution credentials and produces an IPA ready for TestFlight or App Store submission.

---

## ✅ Running Tests

```bash
fastlane test
```

This runs all unit tests on the iPhone 16 simulator and outputs a JUnit XML report. The test suite runs automatically on every pull request.

---

## 🔄 CI/CD Pipeline

PicStrip uses GitHub Actions and Fastlane to automate testing, building, and releasing.

### On Pull Request (any branch)
- **Lint:** SwiftLint strict mode analysis
- **Static Analysis:** `xcodebuild analyze`
- **Unit Tests:** Full test suite on iPhone 16 simulator

### On Push to Main
1. **Version Check:** Semantic-release dry-run determines if a version bump is needed
2. **Build & Beta:** Signs, builds, and uploads to TestFlight
3. **Screenshots:** Captures App Store screenshots automatically
4. **Release:** Publishes GitHub release, tags commit, updates `CHANGELOG.md`
5. **Provenance:** Generates SLSA Level 3 provenance attestation
6. **Assets:** Attaches IPA and SHA-256 checksum to release

---

## 🔒 Privacy & Security

### 100% On-Device Processing
- No internet required
- No analytics or tracking
- No data collection
- No remote servers

PicStrip operates entirely on your device. Every photo is processed locally using Apple's Vision and ImageIO frameworks. The privacy guarantee is enforced by the iOS operating system itself—your photos never leave your device.

### Privacy Manifest
The app declares **zero data collection** and zero tracking domains in `PrivacyInfo.xcprivacy`. The only required-reason API used is ImageIO file encoding (`C617.1`), which is necessary for safe metadata removal.

---

## 📸 Screenshots

> **[Screenshot 1: Home Screen]**
> 
> Animated gradient background with "PicStrip" title and rotating tagline carousel. Lifetime stats capsule shows total photos cleaned and metadata fields stripped.

> **[Screenshot 2: Photo with Metadata & PII]**
> 
> Full-screen image with red bounding boxes highlighting detected PII regions. Bottom panel shows categorized metadata (GPS, EXIF, TIFF, IPTC, etc.) ready for stripping.

> **[Screenshot 3: Redaction Preview]**
> 
> Same photo with opaque black redaction boxes burned over sensitive regions. User can toggle per-field settings before saving.

---

## 📦 App Store

PicStrip is available on the App Store.

[![Download on the App Store](https://img.shields.io/badge/Download-App%20Store-black?logo=apple&logoColor=white&style=for-the-badge)](https://apps.apple.com/app/picstrip/idTODO_REPLACE_WITH_REAL_ID)

> **Note:** Replace `TODO_REPLACE_WITH_REAL_ID` with the actual App Store ID once published.

---

## 🔐 Supply Chain Security (SLSA Level 3)

Every PicStrip release is accompanied by a **SLSA Level 3 provenance attestation**, cryptographically proving that the binary was built by our CI/CD pipeline with no tampering or modifications.

**What this means:**
- ✅ Verifiable proof of origin — built by GitHub Actions, not a developer's laptop
- ✅ Immutable audit trail — every build is logged and timestamped
- ✅ Tampering detection — SHA-256 checksum binds the attestation to the IPA
- ✅ Transparency — all build logs are publicly auditable

**Verify authenticity:**
```bash
slsa-verifier verify-artifact PicStrip.ipa \
  --provenance-path PicStrip.ipa.attestation \
  --source-uri github.com/northcutt-dev/picstrip
```

See [DEVELOPMENT.md](DEVELOPMENT.md#slsa-provenance-level-3) for detailed verification steps and SLSA documentation.

---

## 📄 License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for details.

---

## 🤝 Contributing

Contributions are welcome! Please refer to [DEVELOPMENT.md](DEVELOPMENT.md) for detailed architecture documentation, contributor guidelines, and information on adding new PII detection types.

---

## 📞 Support

For issues, feature requests, or feedback:
- Open an [Issue](https://github.com/northcutt-dev/picstrip/issues)
- Start a [Discussion](https://github.com/northcutt-dev/picstrip/discussions)

---

**Made with ❤️ for privacy.**
