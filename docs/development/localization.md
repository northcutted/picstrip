# Localization

[Developer guide](../../DEVELOPMENT.md)

## Localization

PicStrip localizes user-facing text through Apple string catalogs (English + 16 localizations; Spanish ships as `es` for Spain and `es-419` for Latin America):

- `PicStrip/Localizable.xcstrings` — app, share extension, processing, errors, and accessibility copy
- `PicStrip/AppShortcuts.xcstrings` — App Shortcut phrases that Siri and Spotlight expose
- `PicStrip/InfoPlist.xcstrings`, `PicStripShareExtension/InfoPlist.xcstrings` — photo-library and camera permission prompts and the share-sheet action name ("Clean with PicStrip")
- `fastlane/MarketingHeadlines.xcstrings` — App Store screenshot headline copy (5 keys × 16 locales; `es-MX` falls back to `es`). Read by `scripts/process_screenshots.py` at compose time.

**Translations are LLM-generated.** English is the canonical source; catalogs and `fastlane/metadata/<locale>/` entries are filled in from there. If a translation reads off, edit it inline in the matching catalog or `.txt` file — every locale is editable directly without round-tripping through a translator.

### Rules that keep strings translatable

A missing translation is not a build error — the app silently shows English — so these are enforced by `scripts/audit_xcstrings.py` and `LocalizationTests`, not by the compiler.

| Rule | Why |
|------|-----|
| A string literal only reaches the catalog when its type is `LocalizedStringKey`, `LocalizedStringResource` or `String(localized:)`. A `String` property or parameter (`let detail: String`, `title: String`) shown through `Text(variable)` is **never extracted** and stays English everywhere. | The About screen shipped ~45 English-only strings this way. |
| Never wrap a variable in `LocalizedStringKey(variable)` to "localize" it. | It hides the literal from extraction and does a second lookup on already-localized text. |
| Never assemble a sentence from fragments (`"\(title) \(category) fields"`, `name + ", selected"`). Pass the whole sentence; use accessibility traits for state. | Word order and agreement differ per language. |
| `^[\(n) photo](inflect: true)` is for the **English source only**. Every other locale uses plural variations in the catalog (`one`/`other`, Polish `one/few/many/other`, Arabic all six). | The grammar engine ignores most languages: Polish showed "5 pole". |
| A plural string with a second argument uses an explicit substitution (`%#@instances@` + `argNum`). | Xcode cannot infer which argument drives the plural. |
| One key = one meaning. "High" as a *confidence* band and "High" as a *risk* level are different keys (`ConfidenceLevel.high` vs `High`). | They take different grammatical gender in French, Spanish, Polish, Arabic… |
| Metadata category identifiers (`"GPS"`, `"Apple Maker Note"`) are never shown directly; views call `metadataCategoryDisplayName(for:)`. | The identifier doubles as a `StripConfig` key and must not change. |

### Glossary senses translators must respect

*scan* = analyse a photo for sensitive content — except in "Scan Document", which is capturing paper with the camera and takes each locale's Apple term for document scanning; *redact* = cover part of the picture (never the editorial "edit/write" family: *rédaction*, *redactar*, 編集…); *region* = an area of the image (never a territory); *strip* = remove metadata; *field* = one metadata entry. Platform terms follow Apple's localized iOS (German "Sichern", Dutch "Bewaar", Polish "Zachowaj", Simplified Chinese "存储").

The term each locale uses for these concepts is recorded in [`docs/localization-glossary.md`](../localization-glossary.md). New and changed strings must reuse those terms.

### Commands

```bash
# Hard-coded-string audit + catalog audit (coverage, placeholders, plural categories, inflect misuse).
make audit-localization

# Also prove that every string in the code is in the catalog and nothing in the catalog is dead.
xcodebuild build -project PicStrip.xcodeproj -scheme PicStrip \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/loc \
  CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES
scripts/audit_xcstrings.py --stringsdata build/loc

# Validate JSON shape, both audits, and SwiftLint after edits.
make localization-validate

# Export .xcloc bundles for handoff to a human translator.
make localization-export
```

**Pseudo-localization is available for layout smoke testing.** `bin/ios-release localization-pseudo --languages es fr de` writes `[<lang>] <source>` strings into the missing slots so the UI can be exercised against longer strings, RTL mirroring, and accent-rich glyphs before the real translations land. These pseudo entries must be replaced with real translations before release (`make audit-localization` does not tell them apart from real ones).

```bash
# See what's missing in a catalog without writing.
bin/ios-release localization-pseudo --languages es fr --dry-run

# Pseudo-localize a single catalog for layout smoke testing.
make localization-pseudo LANGUAGES="es"
```

To preview a locale without changing the simulator's language:

```bash
xcrun simctl launch booted com.northcutt.PicStrip -AppleLanguages "(pl)" -AppleLocale pl_PL
```

Do not skip review for App Shortcut phrases, permission prompts, privacy explanations, or redaction/security terms. Those strings carry product trust, and literal machine translations can sound harsher or less precise than intended.

---
