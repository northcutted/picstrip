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
        // These types are handled by NSDataDetector, not the registry
        let dataDetectorTypes: Set<PIIType> = [.phoneNumber, .address, .link]

        for type in PIIType.allCases where !dataDetectorTypes.contains(type) {
            XCTAssertFalse(
                rules(for: type).isEmpty,
                "PIIType.\(type.rawValue) has no DetectionRule — add one or move it to the dataDetectorTypes exclusion set"
            )
        }
    }
}
