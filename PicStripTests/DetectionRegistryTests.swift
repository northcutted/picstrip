import XCTest
@testable import PicStrip

final class DetectionRegistryTests: XCTestCase {

    // MARK: - Helpers

    /// Returns the compiled rules for a given PIIType.
    private func rules(for type: PIIType) -> [DetectionRule] {
        DetectionRegistry.allRules.filter { $0.type == type }
    }

    /// Returns true if any rule for the given type matches within the string.
    private func matches(_ type: PIIType, in string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return rules(for: type).contains { rule in
            rule.regex.firstMatch(in: string, options: [], range: range) != nil
        }
    }

    // MARK: - AWS Access Key

    func testAWSAccessKeyRegex() {
        XCTAssertTrue(matches(.awsAccessKey, in: "AKIAIOSFODNN7EXAMPLE"),
                      "Should detect a standard AWS Access Key ID")
        XCTAssertTrue(matches(.awsAccessKey, in: "Key: AKIAI44QH8DHBEXAMPLE used for S3"),
                      "Should detect AWS key embedded in surrounding text")
        XCTAssertFalse(matches(.awsAccessKey, in: "BKIAIOSFODNN7EXAMPLE"),
                       "Should not match a key not starting with AKIA")
        XCTAssertFalse(matches(.awsAccessKey, in: "AKIA1234"),
                       "Should not match a truncated key (too short)")
    }

    // MARK: - Credit Card

    func testCreditCardRegex() {
        // Visa 16-digit
        XCTAssertTrue(matches(.creditCard, in: "4111111111111111"),
                      "Should detect a Visa card number")
        // Mastercard
        XCTAssertTrue(matches(.creditCard, in: "5500005555555559"),
                      "Should detect a Mastercard number")
        // Amex 15-digit
        XCTAssertTrue(matches(.creditCard, in: "378282246310005"),
                      "Should detect an Amex card number")
        // Spaced display format
        XCTAssertTrue(matches(.creditCard, in: "4111 1111 1111 1111"),
                      "Should detect a Visa card in spaced display format")
        // Dash-separated
        XCTAssertTrue(matches(.creditCard, in: "4111-1111-1111-1111"),
                      "Should detect a Visa card in dash-separated format")
        // Too short — should not match
        XCTAssertFalse(matches(.creditCard, in: "41111111111"),
                       "Should not match a number that is too short to be a card")
    }

    // MARK: - SSN

    func testSSNRegex() {
        XCTAssertTrue(matches(.socialSecurityNumber, in: "123-45-6789"),
                      "Should detect a standard SSN with dashes")
        XCTAssertTrue(matches(.socialSecurityNumber, in: "SSN: 234 56 7890"),
                      "Should detect an SSN with spaces embedded in text")
        // Invalid all-zero segment
        XCTAssertFalse(matches(.socialSecurityNumber, in: "000-45-6789"),
                       "Should not match SSN with 000 area number")
        XCTAssertFalse(matches(.socialSecurityNumber, in: "123-00-6789"),
                       "Should not match SSN with 00 group number")
        XCTAssertFalse(matches(.socialSecurityNumber, in: "123-45-0000"),
                       "Should not match SSN with 0000 serial number")
    }

    // MARK: - GitHub Token

    func testGitHubTokenRegex() {
        XCTAssertTrue(matches(.githubToken, in: "ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890"),
                      "Should detect a GitHub personal access token (ghp_)")
        XCTAssertTrue(matches(.githubToken, in: "gho_aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890"),
                      "Should detect a GitHub OAuth token (gho_)")
        XCTAssertFalse(matches(.githubToken, in: "ghp_short"),
                       "Should not match a token with too few characters after prefix")
        XCTAssertFalse(matches(.githubToken, in: "ghz_aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890"),
                       "Should not match an unknown gh prefix")
    }

    // MARK: - IPv4 Address

    func testIPv4AddressRegex() {
        XCTAssertTrue(matches(.ipAddress, in: "192.168.1.1"),
                      "Should detect a private IPv4 address")
        XCTAssertTrue(matches(.ipAddress, in: "Server at 203.0.113.42 is unreachable"),
                      "Should detect an IPv4 address embedded in text")
        XCTAssertFalse(matches(.ipAddress, in: "999.999.999.999"),
                       "Should not match an out-of-range IPv4 address")
    }

    // MARK: - MAC Address

    func testMACAddressRegex() {
        XCTAssertTrue(matches(.macAddress, in: "00:1A:2B:3C:4D:5E"),
                      "Should detect a colon-separated MAC address")
        XCTAssertTrue(matches(.macAddress, in: "00-1A-2B-3C-4D-5E"),
                      "Should detect a hyphen-separated MAC address")
        XCTAssertFalse(matches(.macAddress, in: "00:1A:2B:3C:4D"),
                       "Should not match a truncated MAC address")
    }

    // MARK: - Stripe Key

    func testStripeKeyRegex() {
        XCTAssertTrue(matches(.stripeKey, in: "sk_live_abcdefghijklmnopqrstuvwx"),
                      "Should detect a Stripe live secret key")
        XCTAssertTrue(matches(.stripeKey, in: "pk_test_abcdefghijklmnopqrstuvwx"),
                      "Should detect a Stripe test publishable key")
        XCTAssertFalse(matches(.stripeKey, in: "sk_staging_abcdefghijklmnopqrstuvwx"),
                       "Should not match a key with an invalid environment label")
    }

    // MARK: - Generic Private Key

    func testGenericPrivateKeyRegex() {
        XCTAssertTrue(matches(.genericPrivateKey, in: "-----BEGIN RSA PRIVATE KEY-----"),
                      "Should detect an RSA private key header")
        XCTAssertTrue(matches(.genericPrivateKey, in: "-----BEGIN EC PRIVATE KEY-----"),
                      "Should detect an EC private key header")
        XCTAssertTrue(matches(.genericPrivateKey, in: "-----BEGIN PRIVATE KEY-----"),
                      "Should detect a generic private key header")
        XCTAssertFalse(matches(.genericPrivateKey, in: "-----BEGIN CERTIFICATE-----"),
                       "Should not match a certificate header")
    }

    // MARK: - IBAN

    func testIBANRegex() {
        XCTAssertTrue(matches(.iban, in: "GB82WEST12345698765432"),
                      "Should detect a UK IBAN")
        XCTAssertTrue(matches(.iban, in: "DE89370400440532013000"),
                      "Should detect a German IBAN")
        XCTAssertFalse(matches(.iban, in: "123456789"),
                       "Should not match a plain number as IBAN")
    }

    // MARK: - Registry completeness

    func testAllPIITypesWithRegexRulesHaveAtLeastOneRule() {
        // Types whose detection is handled outside the regex registry:
        //   • NSDataDetector:  .phoneNumber, .address, .link
        //   • Vision framework: .face, .barcode
        let ruleExemptTypes: Set<PIIType> = [
            .phoneNumber, .address, .link,  // NSDataDetector
            .face, .barcode,                // VNDetectFaceRectanglesRequest / VNDetectBarcodesRequest
        ]

        for type in PIIType.allCases where !ruleExemptTypes.contains(type) {
            XCTAssertFalse(
                rules(for: type).isEmpty,
                "PIIType.\(type.rawValue) has no DetectionRule — add one or move it to the ruleExemptTypes set"
            )
        }
    }

    // MARK: - JWT Token

    func testJWTTokenRegex() {
        // Valid three-part JWT (header.payload.signature, all base64url)
        let validJWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        XCTAssertTrue(matches(.jwtToken, in: validJWT),
                      "Should detect a well-formed JWT")

        // Embedded in surrounding text
        XCTAssertTrue(matches(.jwtToken, in: "Authorization: Bearer \(validJWT)"),
                      "Should detect a JWT in an Authorization header")

        // Only two parts — not a valid JWT, should not match
        XCTAssertFalse(matches(.jwtToken, in: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ"),
                       "A two-part token (missing signature) must not match")

        // Second segment doesn't start with eyJ — header-only fake
        XCTAssertFalse(matches(.jwtToken, in: "eyJhbGciOiJub25lIn0.dGhpcyBpcyBub3QgYSBqd3Q.sig"),
                       "Second segment must also begin with eyJ")
    }

    // MARK: - Developer Secret (vendor tokens)

    func testDeveloperSecretRegex() {
        // Anthropic — sk-ant- prefix + 90+ alphanum chars
        XCTAssertTrue(
            matches(.developerSecret,
                    in: "sk-ant-" + String(repeating: "a", count: 90)),
            "Should detect an Anthropic API key")
        XCTAssertFalse(
            matches(.developerSecret,
                    in: "sk-ant-" + String(repeating: "a", count: 5)),
            "A short Anthropic key must not match")

        // GitLab PAT — glpat- + exactly 20 alphanum chars
        XCTAssertTrue(
            matches(.developerSecret, in: "glpat-" + String(repeating: "x", count: 20)),
            "Should detect a GitLab PAT")
        XCTAssertFalse(
            matches(.developerSecret, in: "glpat-" + String(repeating: "x", count: 10)),
            "A short GitLab PAT must not match")

        // npm — npm_ + 36 alphanum chars
        XCTAssertTrue(
            matches(.developerSecret, in: "npm_" + String(repeating: "A", count: 36)),
            "Should detect an npm access token")

        // HuggingFace — hf_ + 34 alphanum chars
        XCTAssertTrue(
            matches(.developerSecret, in: "hf_" + String(repeating: "B", count: 34)),
            "Should detect a HuggingFace token")

        // DigitalOcean — dop_v1_ + 64 hex chars
        XCTAssertTrue(
            matches(.developerSecret, in: "dop_v1_" + String(repeating: "a", count: 64)),
            "Should detect a DigitalOcean PAT")

        // Twilio account SID — AC + 32 hex chars
        XCTAssertTrue(
            matches(.developerSecret, in: "AC" + String(repeating: "f", count: 32)),
            "Should detect a Twilio account SID")
        XCTAssertFalse(
            matches(.developerSecret, in: "AC" + String(repeating: "f", count: 10)),
            "A short AC token must not match")

        // SendGrid — SG. + 22 chars + . + 43 chars
        XCTAssertTrue(
            matches(.developerSecret,
                    in: "SG." + String(repeating: "x", count: 22) + "." + String(repeating: "y", count: 43)),
            "Should detect a SendGrid API key")

        // Discord bot token — M + 23 alphanum + . + 6 alphanum + . + 27
        let discordToken = "M" + String(repeating: "A", count: 23)
                         + "." + String(repeating: "B", count: 6)
                         + "." + String(repeating: "C", count: 27)
        XCTAssertTrue(matches(.developerSecret, in: discordToken),
                      "Should detect a Discord bot token")
    }

    // MARK: - Database Connection String

    func testConnectionStringRegex() {
        XCTAssertTrue(
            matches(.connectionString, in: "postgres://user:s3cr3t@db.example.com:5432/mydb"),
            "Should detect a PostgreSQL connection string")
        XCTAssertTrue(
            matches(.connectionString, in: "postgresql://admin:pass@localhost/prod"),
            "Should detect a postgresql:// URI")
        XCTAssertTrue(
            matches(.connectionString, in: "mysql://root:hunter2@127.0.0.1:3306/app"),
            "Should detect a MySQL connection string")
        XCTAssertTrue(
            matches(.connectionString, in: "mongodb://user:pwd@cluster0.mongodb.net/db?retryWrites=true"),
            "Should detect a MongoDB connection string")
        XCTAssertTrue(
            matches(.connectionString, in: "mongodb+srv://user:pwd@cluster.mongodb.net/db"),
            "Should detect a mongodb+srv:// URI")
        XCTAssertTrue(
            matches(.connectionString, in: "redis://default:secret@redis.example.com:6379"),
            "Should detect a Redis connection string")
        XCTAssertTrue(
            matches(.connectionString, in: "amqp://guest:guest@rabbitmq.example.com:5672/vhost"),
            "Should detect an AMQP (RabbitMQ) connection string")

        // Plain URL without credentials — must not match
        XCTAssertFalse(
            matches(.connectionString, in: "https://example.com/api"),
            "A plain HTTPS URL must not match")
        // Missing password segment — must not match
        XCTAssertFalse(
            matches(.connectionString, in: "postgres://user@db.example.com/mydb"),
            "A connection string without a password must not match")
    }

    // MARK: - Government ID

    func testGovernmentIDRegex() {
        // Brazilian CPF — 3.3.3-2
        XCTAssertTrue(matches(.governmentID, in: "123.456.789-09"),
                      "Should detect a Brazilian CPF")
        // Wrong separator (comma) — must not match CPF or any other government ID pattern
        XCTAssertFalse(matches(.governmentID, in: "123,456,789-09"),
                       "CPF with comma separators must not match")

        // Italian Codice Fiscale — 6 letters + 2 digits + month letter + 2 digits + muni letter + 3 digits + check
        XCTAssertTrue(matches(.governmentID, in: "RSSMRA85T10A562S"),
                      "Should detect an Italian Codice Fiscale")

        // Spanish NIE — X/Y/Z + 7 digits + letter
        XCTAssertTrue(matches(.governmentID, in: "X1234567A"),
                      "Should detect a Spanish NIE starting with X")
        XCTAssertTrue(matches(.governmentID, in: "Z9876543B"),
                      "Should detect a Spanish NIE starting with Z")

        // Indian PAN — 5 letters + 4 digits + letter
        XCTAssertTrue(matches(.governmentID, in: "ABCDE1234F"),
                      "Should detect an Indian PAN card number")

        // French INSEE — starts with 1 or 2, 13 more digits optionally spaced
        XCTAssertTrue(matches(.governmentID, in: "1 85 12 75 056 018 42"),
                      "Should detect a French INSEE number")
        XCTAssertFalse(matches(.governmentID, in: "3 85 12 75 056 018 42"),
                       "INSEE must start with 1 or 2")

        // Spanish DNI — 8 digits + check letter
        XCTAssertTrue(matches(.governmentID, in: "12345678Z"),
                      "Should detect a Spanish DNI")

        // Aadhaar / Japanese My Number — 4 4 4 with spaces
        XCTAssertTrue(matches(.governmentID, in: "1234 5678 9012"),
                      "Should detect an Aadhaar or My Number (4-4-4 format)")

        // Canadian SIN — 3-3-3 with spaces or hyphens
        XCTAssertTrue(matches(.governmentID, in: "046 454 286"),
                      "Should detect a Canadian SIN with spaces")
        XCTAssertTrue(matches(.governmentID, in: "046-454-286"),
                      "Should detect a Canadian SIN with hyphens")

        // German Steuer-ID — 2-3-3-3 with spaces
        XCTAssertTrue(matches(.governmentID, in: "86 095 742 719"),
                      "Should detect a German Steuer-ID")
    }

    // MARK: - VIN (Vehicle Identification Number)

    func testVehicleIdentificationNumberRegex() {
        // Standard 17-char VIN (ISO 3779) — no I, O, or Q characters.
        XCTAssertTrue(matches(.vehicleIdentificationNumber, in: "1HGBH41JXMN109186"),
                      "Should detect a real 17-char VIN")
        XCTAssertTrue(matches(.vehicleIdentificationNumber, in: "2T1BURHE0JC034546"),
                      "Should detect a Toyota VIN")
        XCTAssertTrue(matches(.vehicleIdentificationNumber, in: "JN1AZ4EH2FM730608"),
                      "Should detect a Nissan VIN")

        // Embedded in surrounding text (e.g. insurance document screenshot)
        XCTAssertTrue(matches(.vehicleIdentificationNumber, in: "VIN: 1HGBH41JXMN109186 (Honda Civic)"),
                      "Should detect a VIN embedded in document text")

        // Too short — 16 chars — must not match
        XCTAssertFalse(matches(.vehicleIdentificationNumber, in: "1HGBH41JXMN10918"),
                       "Should not match a VIN with only 16 characters")

        // Too long — 18 chars — must not match
        XCTAssertFalse(matches(.vehicleIdentificationNumber, in: "1HGBH41JXMN1091862"),
                       "Should not match an 18-char string as a VIN")

        // Contains forbidden letter I — must not match
        XCTAssertFalse(matches(.vehicleIdentificationNumber, in: "1HGBH41JXMNI09186"),
                       "VINs must not contain the letter I")

        // Contains forbidden letter O — must not match
        XCTAssertFalse(matches(.vehicleIdentificationNumber, in: "1HGBH41JXMO109186"),
                       "VINs must not contain the letter O")

        // Contains forbidden letter Q — must not match
        XCTAssertFalse(matches(.vehicleIdentificationNumber, in: "1HGBH41JXMQ109186"),
                       "VINs must not contain the letter Q")
    }

    // MARK: - SWIFT / BIC

    func testSWIFTBICRegex() {
        // ── Positive cases: keyword label present ──────────────────────────────
        // "SWIFT: <code>" — most common document form.
        XCTAssertTrue(matches(.swiftBIC, in: "SWIFT: DEUTDEDB"),
                      "Should detect an 8-char SWIFT code after 'SWIFT:' label")
        XCTAssertTrue(matches(.swiftBIC, in: "BIC: BNPAFRPP"),
                      "Should detect a SWIFT code after 'BIC:' label")
        XCTAssertTrue(matches(.swiftBIC, in: "SWIFT/BIC: CHASUS33"),
                      "Should detect a SWIFT code after 'SWIFT/BIC:' label")
        XCTAssertTrue(matches(.swiftBIC, in: "BIC/SWIFT: CHASUS33"),
                      "Should detect a SWIFT code after 'BIC/SWIFT:' label")
        XCTAssertTrue(matches(.swiftBIC, in: "SWIFT code: BNPAFRPP"),
                      "Should detect a SWIFT code after 'SWIFT code:' label")
        XCTAssertTrue(matches(.swiftBIC, in: "BIC number: DEUTDEDB"),
                      "Should detect a SWIFT code after 'BIC number:' label")

        // Case-insensitive keyword match.
        XCTAssertTrue(matches(.swiftBIC, in: "swift: DEUTDEDB"),
                      "Keyword must be matched case-insensitively")
        XCTAssertTrue(matches(.swiftBIC, in: "bic: BNPAFRPP"),
                      "Keyword 'bic' in lowercase must also match")

        // 11-char form (with 3-char branch code XXX = primary office).
        XCTAssertTrue(matches(.swiftBIC, in: "SWIFT: DEUTDEDBXXX"),
                      "Should detect an 11-char SWIFT code with XXX branch")
        XCTAssertTrue(matches(.swiftBIC, in: "BIC: BOFAUS3NXXX"),
                      "Should detect an 11-char Bank of America BIC")

        // Embedded in surrounding text (e.g. invoice screenshot).
        XCTAssertTrue(matches(.swiftBIC, in: "Wire details — SWIFT/BIC: DEUTDEDB for international"),
                      "Should detect a SWIFT code preceded by the label in a sentence")

        // ── Negative cases: no keyword → must NOT match ────────────────────────
        // Root cause of the original false positive: "COSTANZA" is 8 uppercase
        // letters and structurally satisfies [A-Z]{4}[A-Z]{2}[A-Z0-9]{2}.
        XCTAssertFalse(matches(.swiftBIC, in: "COSTANZA"),
                       "A bare 8-char proper name must NOT match without a keyword")
        XCTAssertFalse(matches(.swiftBIC, in: "DEUTDEDB"),
                       "A bare SWIFT code with no label must not match")
        XCTAssertFalse(matches(.swiftBIC, in: "BOFAUS3NXXX"),
                       "A bare 11-char SWIFT code with no label must not match")
        XCTAssertFalse(matches(.swiftBIC, in: "CHAIRMAN"),
                       "An 8-char English word must not match without a keyword")
        XCTAssertFalse(matches(.swiftBIC, in: "FEEDBACK"),
                       "Another common 8-char word must not match without a keyword")

        // Too short (7 chars) even with a keyword — must not match.
        XCTAssertFalse(matches(.swiftBIC, in: "SWIFT: DEUTDDB"),
                       "A 7-char code after the SWIFT keyword must not match")
    }

    // MARK: - ABA Routing Number

    func testABARoutingNumberRegex() {
        // Standard "routing number: NNNNNNNNN" format
        XCTAssertTrue(matches(.abaRoutingNumber, in: "routing number: 021000021"),
                      "Should detect an ABA routing number after 'routing number:'")
        XCTAssertTrue(matches(.abaRoutingNumber, in: "Routing Number 021000021"),
                      "Should detect a routing number with no colon")
        XCTAssertTrue(matches(.abaRoutingNumber, in: "routing num 021000021"),
                      "Should detect a routing number after 'routing num'")
        XCTAssertTrue(matches(.abaRoutingNumber, in: "Routing No. 021000021"),
                      "Should detect a routing number after 'Routing No.'")

        // "ABA" keyword forms
        XCTAssertTrue(matches(.abaRoutingNumber, in: "ABA: 021000021"),
                      "Should detect a routing number after the 'ABA:' label")
        XCTAssertTrue(matches(.abaRoutingNumber, in: "ABA number 021000021"),
                      "Should detect a routing number after 'ABA number'")
        XCTAssertTrue(matches(.abaRoutingNumber, in: "ABA 021000021"),
                      "Should detect a routing number after bare 'ABA' label")

        // Case-insensitive match
        XCTAssertTrue(matches(.abaRoutingNumber, in: "ROUTING NUMBER: 021000021"),
                      "Routing number keyword match must be case-insensitive")

        // Plain 9-digit number with no keyword — must NOT match (prevents FPs)
        XCTAssertFalse(matches(.abaRoutingNumber, in: "021000021"),
                       "A bare 9-digit number with no context keyword must not match")
        XCTAssertFalse(matches(.abaRoutingNumber, in: "Order #021000021 has shipped"),
                       "A 9-digit order number with no routing keyword must not match")

        // Eight-digit number after keyword — too short, must not match
        XCTAssertFalse(matches(.abaRoutingNumber, in: "routing number: 02100002"),
                       "An 8-digit number must not be accepted as a routing number")
    }
}
