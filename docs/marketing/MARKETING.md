# PicStrip — App Store Marketing Copy

> The single canonical source for App Store text. When you change a field here, change it in the matching file under [`fastlane/metadata/en-US/`](../../fastlane/metadata/en-US) too — the release pipeline uploads from `fastlane/metadata/` on every release, not from this file. This doc exists so reviewers and marketing can read & edit copy without spelunking through `.txt` files.

| | |
|-|-|
| **Bundle ID** | `com.northcutt.PicStrip` |
| **Extension Bundle ID** | `com.northcutt.PicStrip.ShareExtension` |
| **Source of truth (App Store text)** | [`fastlane/metadata/en-US/`](../../fastlane/metadata/en-US) — English is canonical; all 16 supported locales mirrored under `fastlane/metadata/<locale>/` |
| **Source of truth (screenshot copy)** | [`fastlane/MarketingHeadlines.xcstrings`](../../fastlane/MarketingHeadlines.xcstrings) — 5 keys × 16 locales |
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
| **Subtitle** | Strip metadata. Hide secrets. |
| **Primary category** | Photo & Video |
| **Secondary category** | Utilities |
| **Bundle ID** | `com.northcutt.PicStrip` |
| **App Store URL** | https://apps.apple.com/app/picstrip/id6765989071 |

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
Strip metadata. Hide secrets.
```

> 29/30 characters.

### 2.3 Promotional Text · max 170

```
PicStrip strips hidden metadata and redacts 30 kinds of sensitive info — faces, secrets, cards, and more — all on-device. No account, no uploads.
```

> 144/170 characters.

### 2.4 Description · max 4,000

```
Share photos without sharing your location, your identity, or secrets you can't see. PicStrip strips invisible metadata and redacts sensitive info — fully on-device, with no account, no uploads, and zero network calls.

METADATA STRIPPING
Every photo secretly carries GPS coordinates, timestamps, camera make and model, lens data, serial numbers, and Apple maker notes. PicStrip removes all of it before you share — in one tap.

SENSITIVE INFO DETECTION & REDACTION
On-device OCR and computer vision scan your photo for 30 kinds of sensitive personal information (PII), risk-ranked across four tiers:

Critical — API keys, credit cards, social security numbers, passwords, JWTs, database connection strings
High — faces, IBANs, ABA routing numbers, SWIFT/BIC codes, physical credentials
Medium — emails, phones, addresses, crypto wallets, VINs, license plates, IP and MAC addresses
Low — dates of birth, links, barcodes

Each detection shows its type, confidence score, and risk level so you can prioritize what to redact.

REDACTION EDITOR
• Draw anywhere to cover anything the scanner missed
• Multi-select regions and bulk-apply changes at once
• 3 redaction styles: solid, blur, or pixelate
• 10 colors for solid redactions
• 50-step undo/redo

IMPORT FROM ANYWHERE
• Photos library
• Files app — open any image or screenshot directly
• Drag and drop images into the app
• Share Extension — clean directly from Photos, Safari, or any app's share sheet without opening PicStrip

PRIVACY BY DESIGN
• 100% on-device — nothing leaves your phone
• No account, no login, no tracking
• No ads, no in-app purchases, no subscriptions
• Open source — every line of code is auditable on GitHub
• SLSA Level 3 build provenance — every release is cryptographically verified
• Privacy nutrition label: Data Not Collected

SHORTCUTS & AUTOMATION
PicStrip includes a Shortcuts action so you can strip metadata and redact sensitive info automatically: on import, in bulk, or as part of any workflow.
```

### 2.5 Keywords · max 100

```
privacy,EXIF,metadata,GPS,redact,blur,PII,face,risk,detection,anonymize,secure,share,ocr,vision
```

> 95/100 characters.

### 2.6 What's New (Release Notes) · max 4,000

```
What's New

PII DETECTION — 30 TYPES ACROSS 4 RISK TIERS
Every detection is now labelled Critical, High, Medium, or Low so you know exactly what matters most:
• Critical — API keys, credit cards, social security numbers, passwords, JWTs, database connection strings
• High — faces, IBANs, ABA routing numbers, SWIFT/BIC codes, physical credentials
• Medium — emails, phones, addresses, crypto wallets, VINs, license plates, IP/MAC addresses
• Low — dates of birth, links, barcodes

MULTI-SELECT REDACTION EDITOR
Select multiple regions at once and apply style, color, enable/disable, or delete — all in bulk.

3 REDACTION STYLES, 10 COLORS
Solid, blur, or pixelate. Solid blocks support 10 color options per-region or bulk-applied.

50-STEP UNDO/REDO
Every edit is now undoable up to 50 steps.

IMPORT FROM FILES & DRAG AND DROP
Open any image from the Files app or drag and drop directly into PicStrip.
```

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

**Display order** — the App Store carousel shows screenshots 1–3 above the fold (~60% of conversion attribution). Slot 1 is the emotional hook, 2 proves trust, 3 proves detection, 4 shows the redaction editor, 5 closes the loop:

| Display order | Screen key | Headline (en) | Role |
|--------------:|------------|---------------|------|
| 1 | `01_Home` | Share the photo.<br/>Not the story behind it. | Lead with the value prop (strongest emotional hook) |
| 2 | `02_About` | Open source.<br/>Auditable privacy. | Brand trust — the durable differentiator |
| 3 | `03_PhotoLoaded` | Risks ranked.<br/>Nothing missed. | Prove it works — 30-type detection with risk tiers |
| 4 | `04_RedactionEditor` | Multi-select.<br/>Redact your way. | Power feature — multi-select bulk editor |
| 5 | `05_ReviewAndSave` | Export clean.<br/>Share confidently. | Close the loop — clean export |

Display order is set by `SCREENSHOT_DISPLAY_ORDER` in `scripts/process_screenshots.py`. Filenames in `fastlane/screenshots/processed/<locale>/` are renamed at compose time to match this order. To change the order, edit the dict and re-run the compositor — `process_screenshots` wipes `processed/` first so stale PNGs from the previous order don't accumulate.

**Localized variants:** see the full 16-locale matrix in [`fastlane/MarketingHeadlines.xcstrings`](../../fastlane/MarketingHeadlines.xcstrings). Spot-check pairs:

| Locale | `01_Home` | `02_About` |
|--------|-----------|------------|
| **en** | Share the photo. / Not the story behind it. | Open source. / Auditable privacy. |
| **de** | Teile das Foto. / Nicht die Geschichte dahinter. | Open Source. / Prüfbare Privatsphäre. |
| **es** | Comparte la foto. / No la historia detrás. | Código abierto. / Privacidad auditable. |
| **fr** | Partagez la photo. / Pas l'histoire derrière. | Open source. / Confidentialité auditable. |
| **ja** | 写真は共有。/ 背景の情報は守る。 | オープンソース。/ 検証可能なプライバシー。 |
| **ko** | 사진은 공유하세요. / 그 안의 정보는 빼고. | 오픈 소스. / 검증 가능한 프라이버시. |
| **ar** | شارك الصورة. / لا القصة وراءها. | مفتوح المصدر. / خصوصية يمكن تدقيقها. |
| **zh-Hans** | 分享照片。/ 不分享背后的故事。 | 开源代码。/ 隐私可审计。 |

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
| `ar-SA` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `de-DE` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `es-ES` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `fr-FR` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `it`    | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `ja`    | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `ko`    | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `nl-NL` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `pl`    | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `pt-BR` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `pt-PT` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `sv`    | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `tr`    | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `zh-Hans` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| `zh-Hant` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |

All 16 supported locales ship localized ASC text. Translations are LLM-generated from the English canonical copy in `en-US/`; edit any `.txt` file inline if a translation reads off. To add a new locale, drop a `fastlane/metadata/<locale>/` directory with the same set of `.txt` files; `deliver` will pick it up on the next release.

**Release notes localization** — auto-generated by `semantic-release`'s `prepareCmd` into `fastlane/metadata/en-US/release_notes.txt` only. Other locales currently inherit the English release notes at upload time; extend the `prepareCmd` to write into the additional locale directories if you want per-locale notes.

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
