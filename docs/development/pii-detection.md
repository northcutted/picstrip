# PII detection

[Developer guide](../../DEVELOPMENT.md)

## PII Detection Engine

### PIIScanner Pipeline

```
scanImage(data:)
    │
    ├─ [Stage 1] Validate — CGImageSourceCreateWithData + CreateImageAtIndex
    │               ensures a meaningful error before Vision receives bad data
    │
    ├─ [Stage 2] Vision (Swift API) — one handler, one decode
    │   ImageRequestHandler(data)  ← raw Data, not CGImage, to preserve EXIF orientation
    │   performAll([RecognizeTextRequest, DetectFaceRectanglesRequest,
    │               DetectBarcodesRequest, DetectRectanglesRequest])
    │     RecognizeTextRequest
    │       .recognitionLevel = .accurate
    │       .usesLanguageCorrection = false  ← preserve raw credential characters
    │       .automaticallyDetectsLanguage = true
    │   → each request reports its own result or `.error`; one failure never
    │     discards the others (the variadic `perform` would throw for all of them)
    │
    │   If no text → retry with a fresh handler at .fast level
    │   If neither OCR pass produced a result → throw textRecognitionFailed
    │
    └─ [Stage 3] Per-observation analysis
        for each observation:
            ├─ Coordinate flip: Vision bottom-left → SwiftUI top-left
            │     flippedY = 1 - originY - height
            │
            ├─ [Stage B] DetectionRegistry regex sweep  (runs FIRST)
            │     for each rule in allRules:
            │         regex.matches(in: text)
            │         → record(type, baseScore, ocrConfidence, instance)
            │     Tight substring box via candidate.boundingBox(for: swiftRange)
            │     Falls back to observation-level box if API returns nil
            │
            ├─ [Stage A] NSDataDetector  (runs AFTER regex)
            │     Types: .phoneNumber, .address, .link (mailto: → .email)
            │     record() will NOT downgrade a stronger score already set
            │     by the regex pass for overlapping types (e.g., email)
            │
            └─ Orphan-label heuristic
                If neither stage matched AND observation matches bare credential
                keyword ("password:", "login:", garbled OCR variants):
                    stash label → treat NEXT observation as the password value
                    record(.unstructuredCredential, baseScore: 0.65)
```

### Scoring

```
instanceScore = baseScore × ocrConfidence

baseScore:  calibrated per rule (see table below)
            reflects pattern specificity — how likely a match is to be a true positive
ocrConfidence: Vision's per-candidate float (0.0–1.0)
               reflects OCR certainty — how reliably Vision read those characters

result-level score: upgraded when a later match for the same type is stronger
                    ensures the regex pass (higher baseScores) wins over NSDataDetector
                    for overlapping types such as email
```

### PII Type Catalog

All 31 types, by risk tier. Risk is an editorial property of the type and never changes with confidence.

| Risk | Type | Detection |
|------|------|-----------|
| **Critical** | Social Security Number | Regex (`XXX-XX-XXXX`) |
| **Critical** | National Insurance Number | Regex |
| **Critical** | Government ID | Regex (CA SIN, IN PAN/Aadhaar, ES DNI/NIE, BR CPF, DE Steuer-ID, IT Codice Fiscale, FR INSEE, JP My Number, KR RRN, CN Resident ID, PL PESEL, MX CURP, US ITIN/EIN/MBI, US passport, state driver-licence formats) |
| **Critical** | Credit Card Number | Regex + Luhn check |
| **Critical** | AWS Access Key, GitHub Token, Google API Key, OpenAI API Key, Slack Token, Stripe Key | Regex (one type each) |
| **Critical** | Private Key | Regex (PEM header) |
| **Critical** | JWT Token | Regex (double `eyJ` header) |
| **Critical** | Developer Secret | Regex (Anthropic, GitLab PAT, npm, HuggingFace, DigitalOcean, Twilio, SendGrid, Discord) |
| **Critical** | Database Connection String | Regex (inline credentials in a URI) |
| **High** | Face | Vision `DetectFaceRectanglesRequest` |
| **High** | IBAN | Regex + mod-97 check |
| **High** | ABA Routing Number, SWIFT / BIC Code | Regex, keyword-anchored |
| **High** | Physical Credential / Password | Regex (label + value) and a cross-line heuristic |
| **Medium** | Email Address | Regex + `NSDataDetector` |
| **Medium** | Phone Number, Address | `NSDataDetector` |
| **Medium** | Crypto Wallet Address | Regex |
| **Medium** | Vehicle Identification Number | Regex (17 characters, no I/O/Q) + check digit |
| **Medium** | License Plate Number | Regex (structural + keyword-anchored) |
| **Medium** | MAC Address, IP Address | Regex |
| **Low** | Date of Birth | Regex, keyword-anchored (DOB / Born / Birthday) |
| **Low** | Link / URL | `NSDataDetector` |
| **Low** | QR Code / Barcode | Vision `DetectBarcodesRequest` |
| **Low** | Name | Apple's on-device language model (app only, Apple Intelligence; listed but not redacted by default) |

The full rule set is `DetectionRegistry.build()` (60 rules). Representative base scores, to show the calibration bands:

| Type | Detection | Base score |
|------|-----------|------------|
| AWS Access Key / Google API Key | Regex | 0.98 |
| GitHub, OpenAI, Slack, Stripe keys | Regex | 0.97 |
| Private Key (PEM) | Regex | 0.96 |
| Social Security Number, Credit Card (compact) | Regex | 0.94 |
| Email Address, IBAN | Regex | 0.93 |
| IP Address (IPv4) | Regex | 0.90 |
| Date of Birth (keyword-anchored) | Regex | 0.85 |
| Credit Card (spaced/dashed) | Regex | 0.80 |
| Email via `mailto:` link | `NSDataDetector` | 0.75 |
| Phone Number | `NSDataDetector` | 0.72 |
| Address | `NSDataDetector` | 0.68 |
| Physical Credential (label + value on one line) | Regex | 0.68 |
| Physical Credential (value on the next line) | Cross-line heuristic | 0.65 |
| Name | On-device language model | 0.62 |
| Link / URL | `NSDataDetector` | 0.52 |

**Why `usesLanguageCorrection = false`:** Vision's language correction normalises "AIzaSy..." into dictionary words. Disabled to preserve raw credential characters.

**Why `.accurate` first with `.fast` fallback:** The Neural Engine is unavailable in the simulator; the `.accurate` model returns zero observations on simulator CPU paths. The retry uses a fresh `ImageRequestHandler`.

**Face detector revision:** a default-initialised `DetectFaceRectanglesRequest` still resolves to revision 3 on iOS 27, so revision 4 is requested by name — on devices only (it is unimplemented in the simulator) and behind `#if compiler(>=6.4)` + `#available(iOS 27, *)`. If it errors, `scanImage` retries face detection with the default revision and a failed retry remains visible in `ScanCoverage`. A completed detector can still miss a face.

### Duplicate Detection

`DetectedInstance` conforms to `Equatable` on `(snippet, boundingBox)`. When both the regex pass and `NSDataDetector` fire on the same text span, `record()` silently drops the duplicate and only upgrades the score if the new instance is stronger.

---


## Contributing: Adding a New PII Type

### Step 1 — Define the type

Add a case to `PIIType.swift`:

```swift
enum PIIType: String, Hashable, Identifiable, CaseIterable {
    // ... existing cases ...

    // MARK: - Financial
    case bankRoutingNumber  // new

    nonisolated var description: String {
        switch self {
        // ...
        case .bankRoutingNumber: return "Bank Routing Number"
        }
    }
}
```

### Step 2 — Add a detection rule

In `DetectionRule.swift` (inside the `build()` function):

```swift
// US routing numbers: exactly 9 digits, common in financial docs
rule(.bankRoutingNumber,
     #"\b\d{9}\b"#,
     0.70)
```

Choose a `baseScore` that reflects how many false positives the pattern is likely to produce:
- `≥ 0.95` — globally unique prefix (AWS key, GitHub token)
- `0.85–0.94` — strong structure (SSN, credit card, IBAN)
- `0.70–0.84` — good structure but ambiguous in some contexts
- `0.50–0.69` — heuristic / contextual; use sparingly

### Step 3 — Update AboutView (optional)

`AboutView.swift` contains a static PII catalogue displayed in the app's About screen. Add a row for the new type if it should be visible to users.

### Step 4 — Write tests

In `PicStripTests/PIIScannerTests.swift`:

```swift
func testDetectsBankRoutingNumber() async throws {
    let image = try createTestImage(withText: "Routing: 021000021")
    let results = try await PIIScanner().scanImage(data: image)
    let hit = try XCTUnwrap(results.first { $0.type == .bankRoutingNumber })
    XCTAssertGreaterThan(hit.score, 0.6)
    XCTAssertFalse(hit.instances.isEmpty)
}
```

### Step 5 — Test end-to-end

1. `make test` — verify the new test passes in the unit test suite.
2. Run the app; open a photo containing a routing number.
3. Confirm the red overlay lands on the correct region.
4. Toggle redaction; confirm the black box covers the number in the saved image.
5. Check the audit JSON — the new type should appear under `visualRedactions`.

---
