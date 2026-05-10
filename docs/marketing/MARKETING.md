# PicStrip — App Store Marketing Copy

> The single canonical source for App Store text. When you change a field here, change it in the matching file under [`fastlane/metadata/en-US/`](../../fastlane/metadata/en-US) too — the release pipeline uploads from `fastlane/metadata/` on every release, not from this file. This doc exists so reviewers and marketing can read & edit copy without spelunking through `.txt` files.

| | |
|-|-|
| **Bundle ID** | `com.northcutt.PicStrip` |
| **Extension Bundle ID** | `com.northcutt.PicStrip.ShareExtension` |
| **Source of truth (App Store text)** | [`fastlane/metadata/en-US/`](../../fastlane/metadata/en-US) (+ `de-DE`, `fr-FR`, `es-ES`, `ja`) |
| **Source of truth (screenshot copy)** | [`fastlane/MarketingHeadlines.xcstrings`](../../fastlane/MarketingHeadlines.xcstrings) — 7 keys × 16 locales |
| **Source of truth (screenshots)** | [`fastlane/screenshots/processed/`](../../fastlane/screenshots/processed) (Git LFS) |
| **App version** | Tracked in `MARKETING_VERSION` (auto-bumped by `semantic-release`) — see [`CHANGELOG.md`](../../CHANGELOG.md) for history |
| **Per-version release notes** | [`fastlane/metadata/en-US/release_notes.txt`](../../fastlane/metadata/en-US/release_notes.txt) — auto-generated from commits |

---

## Table of contents

1. [App identity](#1-app-identity)
2. [Copy-paste fields (App Store Connect form order)](#2-copy-paste-fields-app-store-connect-form-order)
3. [Screenshot headlines](#3-screenshot-headlines)
4. [App Review information](#4-app-review-information)
5. [Privacy nutrition label](#5-privacy-nutrition-label)
6. [Compliance & ratings](#6-compliance--ratings)
7. [Localization coverage](#7-localization-coverage)
8. [Pricing & availability](#8-pricing--availability)

---

## 1. App identity

| Field | Value |
|------|------|
| **App name** | PicStrip |
| **Subtitle** | Photo privacy in one tap |
| **Primary category** | Photo & Video |
| **Secondary category** | Utilities |
| **Bundle ID** | `com.northcutt.PicStrip` |
| **App Store URL** | _Replace `idTODO_REPLACE_WITH_REAL_ID` in [`README.md`](../../README.md) once published_ |

**Brand palette** (used in marketing screenshots):

| Role | Hex | RGB |
|------|-----|-----|
| Brand top (gradient highlight) | `#20785A` | 32, 120, 90 |
| Brand bottom (gradient anchor) | `#0A382A` | 10, 56, 42 |
| Headline | `#FFFFFF` | 255, 255, 255 |
| Headline stroke | `#041E16` | 4, 30, 22 |

---

## 2. Copy-paste fields (App Store Connect form order)

Each block below is **exactly** what to paste into the corresponding App Store Connect form field. Character limits are noted next to each section header.

### 2.1 App Name · max 30

```
PicStrip
```

### 2.2 Subtitle · max 30

```
Photo privacy in one tap
```

> 24/30 characters. The previous subtitle ("Strip photo metadata instantly") was 30/30 but feature-led — "metadata" is jargon non-technical users don't search for. This version trades the tight word "instantly" for the benefit framing ("privacy") that drives App Store browse-and-tap conversion. Room remains to add a region or qualifier in localized variants.

### 2.3 Promotional Text · max 170

```
Every iPhone photo carries your exact GPS, the time, and your camera fingerprint. PicStrip removes it all in one tap — 100% on-device. No account, no uploads.
```

> 158/170 characters. Promotional text can be edited without resubmitting for review — use it for time-bound campaigns (launches, World Privacy Day) or audience-specific hooks (real-estate sellers, Marketplace listers, journalists). The current version leads with the *threat* the user didn't know they had, then resolves it; consider rotating the opener seasonally.

### 2.4 Description · max 4,000

```
Sent someone a photo lately? You probably also sent your home GPS coordinates, the exact time it was taken, and your camera's serial number — embedded invisibly in the file. PicStrip removes all of it before you share, in one tap, 100% on your device.

No account. No uploads. No tracking. Just clean photos.

WHAT GETS REMOVED
• GPS location — precise coordinates embedded in every photo
• Timestamps — when the photo was taken, edited, and digitized
• Device info — camera make, model, lens, and software version
• Personal identifiers — author name, copyright, and serial numbers
• Private camera analysis — Apple maker-note data where present

PRIVACY BY DESIGN
• Runs entirely on-device — nothing is uploaded anywhere
• No account, no login, no tracking
• No ads, no in-app purchases, no subscriptions

WHY YOU CAN TRUST IT
• Open source — every line of code is public and auditable on GitHub
• SLSA Level 3 build provenance — every release is cryptographically verified
• Zero third-party SDKs in the final binary; no analytics, no network calls
• Privacy nutrition label declares "Data Not Collected" — the strongest possible answer

HOW IT WORKS
1. Tap to select a photo from your library
2. PicStrip scans for all embedded metadata
3. Review exactly what was found
4. Strip it — your clean photo saves to your library instantly

SHARE EXTENSION
Strip metadata directly from the share sheet in Photos, Safari, or any app — without ever opening PicStrip.

SHORTCUTS & AUTOMATION
PicStrip includes a Shortcuts action so you can build automated workflows: strip metadata on import, process photos in bulk, or integrate with your existing shortcuts.
```

> 1702/4000 characters. The new "WHY YOU CAN TRUST IT" block surfaces the unique trust signals (open source, SLSA Level 3 provenance, zero SDKs, "Data Not Collected" nutrition label) that competitor metadata strippers can't match. These signals matter most to the privacy-conscious user who reads reviews and writes them — i.e. exactly the audience that drives word-of-mouth for utility apps.

### 2.5 Keywords · max 100

```
privacy,EXIF,metadata,GPS,location,redact,blur,anonymize,geotag,scrub,sensitive,secure,share
```

> 92/100 characters. Comma-separated, no spaces, no trailing punctuation. Apple ranks keywords above the description, so this is the highest-leverage ASO lever. Notes on the current set:
>
> - Removed `photo` (implied by the Photo & Video category — Apple already indexes that signal), `strip` (already in app name), `clean` and `remove` (overlap with `strip`/`scrub`).
> - Added `redact`, `blur`, `anonymize` to grab users searching for the *redaction* feature, not just metadata stripping.
> - Added `geotag` because it's the term most non-technical users actually search when they want to remove location data.
> - Added `share` because intent-driven phrasing ("anonymize before share") shows up well in autocomplete.

### 2.6 What's New (Release Notes) · max 4,000

```
Features
• Add support for handling alpha channel in PNG metadata
Bug Fixes
• harden unit tests, rename Fastfile lane, refresh screenshots
• replace fixed sleep with polling wait in testFocusPIIResult
```

> Auto-generated by `semantic-release` from commit messages and committed to [`fastlane/metadata/en-US/release_notes.txt`](../../fastlane/metadata/en-US/release_notes.txt) at release time. If you want different copy in the App Store than what semantic-release produced, edit the file in the same commit and the submission lane will pick it up.

### 2.7 URLs

| Field | Value |
|------|------|
| **Marketing URL** | `https://github.com/northcutted/picstrip` |
| **Support URL** | `https://github.com/northcutted/picstrip` |
| **Privacy Policy URL** | `https://github.com/northcutted/picstrip/blob/main/PRIVACY.md` |

### 2.8 Copyright

```
Copyright 2025 Eddie Northcutt
```

---

## 3. Screenshot headlines

Marketing screenshots are composed in `scripts/process_screenshots.py`: brand-gradient canvas, custom matte-black device frame, localized headline above. Source-of-truth text lives in [`fastlane/MarketingHeadlines.xcstrings`](../../fastlane/MarketingHeadlines.xcstrings) and is hand-translated into all 16 supported locales.

**Display order** — the App Store carousel shows screenshots 1–3 above the fold (~60% of conversion attribution). Slot 1 is the emotional hook, 2 proves the product works, 3 closes the loop:

| Display order | Screen key | Headline (en) | Role |
|--------------:|------------|---------------|------|
| 1 | `01_Home` | Share the photo.<br/>Not the story behind it. | Lead with the value prop (strongest emotional hook) |
| 2 | `04_PhotoLoaded` | Sensitive data<br/>caught instantly. | Prove it works (detection) |
| 3 | `07_ReviewAndSave` | Export clean.<br/>Share confidently. | Close the loop (clean export) |
| 4 | `05_RedactionEditor` | Draw to hide<br/>anything sensitive. | Power feature — manual redaction |
| 5 | `06_SensitiveData` | See exactly<br/>what gets hidden. | Trust / transparency |
| 6 | `02_PrivacyImpact` | GPS. Time. Camera ID.<br/>All stripped automatically. | Breadth of metadata stripped |
| 7 | `03_About` | Open source.<br/>Auditable privacy. | Brand close — the durable differentiator |

Display order is set by `SCREENSHOT_DISPLAY_ORDER` in `scripts/process_screenshots.py`. Filenames in `fastlane/screenshots/processed/<locale>/` are renamed at compose time to match this order. To change the order, edit the dict and re-run the compositor — `process_screenshots` wipes `processed/` first so stale PNGs from the previous order don't accumulate.

**Localized variants:** see the full 16-locale matrix in [`fastlane/MarketingHeadlines.xcstrings`](../../fastlane/MarketingHeadlines.xcstrings). Spot-check pairs:

| Locale | `01_Home` | `03_About` |
|--------|-----------|------------|
| **en** | Share the photo. / Not the story behind it. | Open source. / Auditable privacy. |
| **de** | Teile das Foto. / Nicht die Geschichte dahinter. | Open Source. / Prüfbare Privatsphäre. |
| **es** | Comparte la foto. / No la historia detrás. | Código abierto. / Privacidad auditable. |
| **fr** | Partagez la photo. / Pas l'histoire derrière. | Open source. / Confidentialité auditable. |
| **ja** | 写真は共有。/ 背景の情報は守る。 | オープンソース。 / 検証可能なプライバシー。 |
| **ko** | 사진은 공유하세요. / 그 안의 정보는 빼고. | 오픈 소스. / 검증 가능한 프라이버시. |
| **ar** | شارك الصورة. / لا القصة وراءها. | مفتوح المصدر. / خصوصية يمكن تدقيقها. |
| **zh-Hans** | 分享照片。/ 不分享背后的故事。 | 开源代码。 / 隐私可审计。 |

---

## 4. App Review information

Source: [`fastlane/metadata/review_information/`](../../fastlane/metadata/review_information).

| Field | Value |
|------|------|
| **First name** | Eddie |
| **Last name** | Northcutt |
| **Phone number** | +1 618-541-8770 |
| **Email** | northcutted@gmail.com |
| **Demo account user** | _(none — leave blank)_ |
| **Demo account password** | _(none — leave blank)_ |

**Notes for App Review:**

```
No login or demo credentials required. The app works entirely with photos from the device library. Select any photo to begin.
```

**Reviewer test plan (suggested wording if more detail is requested):**

```
1. Launch PicStrip and grant Photos read access when prompted.
2. Tap "Choose Photo" and pick any image from the simulator's photo library (the bundled Photos library samples include images with GPS metadata).
3. Confirm the metadata panel shows GPS, EXIF, and TIFF fields with values populated.
4. Tap "Save Cleaned Copy". The cleaned image is saved back to the simulator photo library — no network request is made.
5. Optional: open the iOS Share Sheet from Photos, choose PicStrip, and confirm the share extension processes a photo without opening the main app.

The app uses no remote services. Network Inspector in Xcode confirms zero outbound connections at any point in the flow.
```

---

## 5. Privacy nutrition label

PicStrip declares **zero data collection** and **zero tracking** in [`PrivacyInfo.xcprivacy`](../../PicStrip/PrivacyInfo.xcprivacy). Re-declare in App Store Connect → App Privacy as:

| App Store Connect prompt | Answer |
|--------------------------|--------|
| Do you or your third-party partners collect data from this app? | **No** |
| Does your app use third-party SDKs? | **No** |
| Required-reason API usage | `NSPrivacyAccessedAPICategoryFileTimestamp` (`C617.1`) — for ImageIO file timestamp access during metadata extraction. **Not** for fingerprinting or tracking. |

**Permission strings (Info.plist):**

| Key | Copy |
|-----|------|
| `NSPhotoLibraryAddUsageDescription` | "PicStrip saves the cleaned copy back to your photo library." (add-only) |
| `NSPhotoLibraryUsageDescription` | "Replace Original requires read access so PicStrip can delete the source after saving the cleaned copy." (read + write) |

These strings ship in [`PicStrip/Localizable.xcstrings`](../../PicStrip/Localizable.xcstrings) and are localized to all 16 supported locales.

**Accessibility Nutrition Label:** declared in [`fastlane/accessibility_declarations.json`](../../fastlane/accessibility_declarations.json) and synced via `bundle exec fastlane accessibility` (also chained from the `submit` lane).

---

## 6. Compliance & ratings

| Field | Value |
|------|------|
| **Age rating** | 4+ |
| **Content rights** | Original work — Eddie Northcutt holds rights to all source code and brand assets |
| **Uses encryption** | App uses only standard iOS cryptography (`CryptoKit`, `CommonCrypto`); no custom or restricted encryption is implemented. The `ITSAppUsesNonExemptEncryption` Info.plist key is set to `false` (exempt under the U.S. Export Administration Regulations §740.17(b)(3)(i) — uses only standard encryption inside iOS for connectivity, authentication, and data integrity). |
| **Third-party content** | None |
| **Made for kids** | No |
| **Government/enterprise** | No |

---

## 7. Localization coverage

PicStrip is localized into **16 locales**. Each locale ships:

- Runtime app strings via `PicStrip/Localizable.xcstrings`
- Siri / Shortcuts phrases via `PicStrip/AppShortcuts.xcstrings`
- Marketing screenshot headlines via `fastlane/MarketingHeadlines.xcstrings`
- Marketing PNGs in `fastlane/screenshots/processed/<locale>/` (Git LFS)

| Code | Language | Region focus |
|------|----------|--------------|
| `en-US` | English | United States |
| `ar-SA` | Arabic | Saudi Arabia (RTL) |
| `de-DE` | German | Germany |
| `es-ES` | Spanish | Spain |
| `fr-FR` | French | France |
| `it` | Italian | Italy |
| `ja` | Japanese | Japan |
| `ko` | Korean | Korea |
| `nl-NL` | Dutch | Netherlands |
| `pl` | Polish | Poland |
| `pt-BR` | Portuguese | Brazil |
| `pt-PT` | Portuguese | Portugal |
| `sv` | Swedish | Sweden |
| `tr` | Turkish | Türkiye |
| `zh-Hans` | Chinese (Simplified) | Mainland China |
| `zh-Hant` | Chinese (Traditional) | Taiwan / Hong Kong |

App Store Connect localized text field coverage:

| Locale | name | subtitle | promotional_text | description | keywords | URLs | release_notes |
|--------|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `en-US` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ (auto-generated by semantic-release) |
| `de-DE` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `fr-FR` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `es-ES` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `ja`    | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| 11 other locales | — | — | — | — | — | — | — |

**Why these 4 locales:** Germany, France, Spain, and Japan are the largest non-English iOS revenue markets where English subtitle/description copy demonstrably under-converts. Translating them (vs. shipping English in those storefronts) is the highest-leverage ASO move available. The remaining 11 supported locales still ship English ASC text — but their localized in-app strings, App Shortcut phrases, and screenshot headlines render natively because those live in the `.xcstrings` catalogs. To add a new locale, drop a `fastlane/metadata/<locale>/` directory with the same set of `.txt` files; `deliver` will pick it up on the next release.

**Release notes localization** — auto-generated by `semantic-release`'s `prepareCmd` into `fastlane/metadata/en-US/release_notes.txt` only. To localize, either translate manually after each release, or extend the `prepareCmd` to write into the additional locale directories. The technical release-note language ("harden unit tests", "polling wait") translates poorly without context, so manual is recommended.

---

## 8. Pricing & availability

| Field | Value |
|------|------|
| **Price tier** | Free |
| **In-App Purchases** | None |
| **Subscriptions** | None |
| **Availability** | All territories |
| **Pre-order** | Not used |
| **Phased release** | Enabled (7-day staged rollout — `phased_release: true` in `submit` lane) |
| **Automatic release on approval** | Enabled (`automatic_release: true` in `submit` lane) |

---

## Workflow: how to ship a copy change

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Edit fastlane/metadata/en-US/<field>.txt with the new copy.  │
│ 2. Edit this file so the canonical doc matches.                 │
│ 3. Commit on a feature branch (Conventional Commits).           │
│ 4. Open a PR. PR checks run lint/analyze/test.                  │
│ 5. Merge to main → semantic-release cuts a version → main.yml   │
│    pipeline ships the IPA + metadata together.                  │
└─────────────────────────────────────────────────────────────────┘
```

**Promotional text and URLs** can be edited in App Store Connect without resubmitting for review. Other fields require a new submission. If a copy change is the only change in a PR, it still triggers a release because semantic-release counts `feat:`/`fix:` commits — use `chore:` for copy-only edits if you don't want a version bump.

## Workflow: how to refresh screenshots after a UI change

```bash
# Local one-shot (re-uses the API key from your keychain).
make upload-screenshots                  # process + upload from raw captures

# CI path (preferred — keeps API keys off your workstation).
gh workflow run screenshots.yml \
  -f generate_new=true \
  -f languages=en-US,de-DE,ja            # optional locale subset
```

The CI path commits the regenerated marketing PNGs back to `main` via Git LFS with `[skip ci]`, then uploads them to App Store Connect. Subsequent runs of the same workflow with `generate_new=false` (the default) will reuse those committed PNGs.

---

_Per-version release notes live in [`fastlane/metadata/en-US/release_notes.txt`](../../fastlane/metadata/en-US/release_notes.txt) (auto-generated by `semantic-release`) and [`CHANGELOG.md`](../../CHANGELOG.md). Significant marketing changes are tracked in the git history of this file._
