import Foundation

// MARK: - DetectionRule

/// A compiled rule pairing a PIIType with a pre-built NSRegularExpression
/// and a calibrated base score (0.0–1.0) reflecting how specific and
/// structurally unambiguous the pattern is.
///
/// The final per-instance confidence is:  `baseScore × ocrConfidence`
/// where `ocrConfidence` is the Vision OCR float for the observation the
/// match was found in (0.0–1.0). This means identical patterns in crisp
/// vs. blurry text naturally produce different displayed percentages.
///
/// Regex objects are expensive to construct — all rules are compiled once at
/// registry initialisation time and reused across every scan.
struct DetectionRule {
    let type: PIIType
    let regex: NSRegularExpression
    /// Pattern specificity weight, independent of OCR quality. Multiply by
    /// the Vision OCR confidence to get the final instance score.
    let baseScore: Double
}

// MARK: - DetectionRegistry

enum DetectionRegistry {

    /// All regex-based detection rules, compiled once at first access.
    /// NSDataDetector handles .address, .phoneNumber, and plain .link natively;
    /// those types are intentionally absent here and remain in PIIScanner.
    static let allRules: [DetectionRule] = build()

    // MARK: - Private helpers

    /// Builds the rule list using an explicit local helper to avoid dot-syntax
    /// ambiguity inside array literals.
    private static func build() -> [DetectionRule] {
        func rule(_ type: PIIType, _ pattern: String, _ baseScore: Double) -> DetectionRule {
            // try! is intentional: a bad pattern is a programmer error, not a runtime condition.
            // These are compiled once at startup; any regex mistake must fail fast during development.
            let regex = try! NSRegularExpression(pattern: pattern, options: [])
            return DetectionRule(type: type, regex: regex, baseScore: baseScore)
        }

        return [
            // MARK: Contact
            // Email — well-defined RFC structure; very specific.
            // Base 0.93: the regex is tight but OCR can smear @ or dots.
            rule(.email,
                 #"[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,64}"#,
                 0.93),

            // MARK: Network
            // IPv4 — four 0-255 octets; structurally unambiguous.
            rule(.ipAddress,
                 #"\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b"#,
                 0.90),

            // IPv6 — full or compressed forms; lower base because OCR
            // frequently corrupts colons into semicolons or spaces.
            rule(.ipAddress,
                 #"\b(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\b"#,
                 0.76),

            // MAC address — six hex pairs; short and easily confused with
            // other colon-separated values.
            rule(.macAddress,
                 #"\b(?:[0-9a-fA-F]{2}[:\-]){5}[0-9a-fA-F]{2}\b"#,
                 0.72),

            // MARK: Identity
            // US SSN — 3-2-4 with dashes or spaces, anti-zero guards; high.
            rule(.socialSecurityNumber,
                 #"\b(?!000|666|9\d{2})\d{3}[\ \-](?!00)\d{2}[\ \-](?!0000)\d{4}\b"#,
                 0.94),

            // Date of birth — common formats: MM/DD/YYYY and YYYY-MM-DD.
            // Low base because date strings appear constantly in non-sensitive contexts.
            rule(.dateOfBirth,
                 #"\b(?:0?[1-9]|1[0-2])[\/\-](?:0?[1-9]|[12]\d|3[01])[\/\-](?:19|20)\d{2}\b"#,
                 0.48),
            rule(.dateOfBirth,
                 #"\b(?:19|20)\d{2}[\/\-](?:0?[1-9]|1[0-2])[\/\-](?:0?[1-9]|[12]\d|3[01])\b"#,
                 0.48),

            // UK National Insurance number — two-letter prefix (with exclusions
            // for invalid starting letters per HMRC spec), six digits, one suffix
            // letter A-D.  Space-separated display form is also matched.
            // Base 0.91 — format is specific enough after letter exclusions.
            rule(.nationalInsuranceNumber,
                 #"\b[A-CEGHJ-PR-TW-Z]{2}[\ ]?[0-9]{2}[\ ]?[0-9]{2}[\ ]?[0-9]{2}[\ ]?[A-D]\b"#,
                 0.91),

            // MARK: Financial
            // Credit card — compact (no separators); Luhn intentionally omitted
            // since OCR may corrupt digits; structurally specific prefixes.
            rule(.creditCard,
                 #"\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13}|6(?:011|5[0-9]{2})[0-9]{12})\b"#,
                 0.94),

            // Credit card with spaces or dashes (common display format);
            // slightly lower because the pattern is looser with separators.
            rule(.creditCard,
                 #"\b(?:4[0-9]{3}|5[1-5][0-9]{2}|3[47][0-9]{2}|6011)[\ \-]?[0-9]{4}[\ \-]?[0-9]{4}[\ \-]?[0-9]{4}\b"#,
                 0.80),

            // IBAN — 2-letter country code, 2 check digits, up to 30 alphanum.
            rule(.iban,
                 #"\b[A-Z]{2}[0-9]{2}[A-Z0-9]{4}[0-9]{7}(?:[A-Z0-9]{0,18})?\b"#,
                 0.93),

            // Crypto wallet addresses:
            //   Ethereum — 0x prefix + exactly 40 hex chars; fixed length makes
            //   this very specific.  Base 0.87 because short hex strings appear
            //   in other contexts (colour values, hashes).
            rule(.cryptoWallet,
                 #"\b0x[0-9a-fA-F]{40}\b"#,
                 0.87),
            //   Bitcoin Bech32 (native SegWit) — bc1q or bc1p prefix + 6-87
            //   lowercase alphanum chars.  Legacy P2PKH (1...) and P2SH (3...)
            //   formats are intentionally excluded: their loose prefix causes too
            //   many false positives with other numeric strings.
            rule(.cryptoWallet,
                 #"\bbc1[a-z0-9]{6,87}\b"#,
                 0.88),

            // MARK: Developer Secrets
            // AWS Access Key ID — exact AKIA prefix + 16 alphanumeric chars.
            rule(.awsAccessKey,
                 #"\bAKIA[0-9A-Z]{16}\b"#,
                 0.98),

            // GitHub personal access token (classic ghp_, gho_, ghu_, ghs_, ghr_).
            rule(.githubToken,
                 #"\bgh[pousr]_[A-Za-z0-9]{36}\b"#,
                 0.97),

            // Google API key — exact AIza prefix + 35 URL-safe alphanum chars.
            // The prefix is globally unique to Google Cloud credentials.
            rule(.googleAPIKey,
                 #"\bAIza[0-9A-Za-z\-_]{35}\b"#,
                 0.98),

            // OpenAI API key — two active formats:
            //   Legacy: sk- + 48 alphanum chars
            //   Project-scoped: sk-proj- + 48+ alphanum/hyphen/underscore chars
            rule(.openAIKey,
                 #"\bsk-[A-Za-z0-9]{48}\b"#,
                 0.97),
            rule(.openAIKey,
                 #"\bsk-proj-[A-Za-z0-9\-_]{48,}\b"#,
                 0.97),

            // Slack bot/user/app tokens — exact xox[baprs]- prefix.
            rule(.slackToken,
                 #"\bxox[baprs]-[0-9A-Za-z\-]{10,72}\b"#,
                 0.97),

            // Stripe secret and publishable keys — exact sk_/pk_ + env prefix.
            rule(.stripeKey,
                 #"\bsk_(?:live|test)_[0-9a-zA-Z]{24,}\b"#,
                 0.97),
            rule(.stripeKey,
                 #"\bpk_(?:live|test)_[0-9a-zA-Z]{24,}\b"#,
                 0.97),

            // Generic PEM private key header — exact delimiter string.
            rule(.genericPrivateKey,
                 #"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"#,
                 0.96),

            // MARK: Unstructured / Contextual
            // Heuristic for physical credentials on whiteboards, sticky notes, etc.
            //
            // Design rationale:
            //   • The keyword alternation covers clean forms AND heavily garbled OCR
            //     variants: Vision may clip letters, substitute digits for letters
            //     (O→0), or insert spaces mid-word. Rather than enumerating all
            //     variants, we match a broad "label-like token" (≤12 chars, no digit
            //     run suggesting a value) followed by a required separator.
            //   • Separator [*•:.\-=] is REQUIRED to keep false-positive rate low.
            //     Vision substitutes • for :, and - for – etc.
            //   • Value capture [^\n]{2,} accepts spaces (spaced handwriting).
            //   • No ^ anchor — OCR may prepend stray characters.
            // Base 0.68 — separator requirement reduces FPs but the pattern
            // is ultimately heuristic.
            rule(.unstructuredCredential,
                 #"(?i)(?:[a-z0-9 ]{0,12}(?:login|log ?in|pass(?:word)?|pwd|user(?:name)?|cred(?:ential)?s?|ha[sś][łl]o|haslo|islo|iso|g?in|ogin|0g ?in|min))\s*[*•:.\-=]\s*([^\n]{2,})"#,
                 0.68),
        ]
    }
}
