import XCTest
@testable import PicStrip

/// Runtime checks on the compiled string tables inside the test host app.
///
/// `scripts/audit_xcstrings.py` audits the catalog source; these tests prove the
/// compiled result behaves — in particular that plural strings resolve per
/// locale instead of showing English `^[…](inflect: true)` markup or a singular
/// noun for every count.
final class LocalizationTests: XCTestCase {

    private static let locales = [
        "ar", "de", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt-BR", "pt-PT", "sv", "tr", "zh-Hans", "zh-Hant"
    ]

    private func table(for locale: String) throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: locale, ofType: "lproj"),
            "The app should ship a \(locale).lproj."
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    private func format(_ key: String, locale: String, _ arguments: CVarArg...) throws -> String {
        let format = try table(for: locale).localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: Locale(identifier: locale), arguments: arguments)
    }

    /// Strings that were English-only in every locale before the catalog audit existed.
    func testPreviouslyUntranslatedStringsAreTranslatedEverywhere() throws {
        for locale in Self.locales {
            for key in ["Save to Photos", "Select All", "Scanning…", "Strip All", "Risk Level"] {
                let value = try table(for: locale).localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(value, key, "\(locale) still shows English for “\(key)”.")
            }
        }
    }

    func testPluralStringsNeverLeakMarkup() throws {
        let keys = [
            "^[%lld photo](inflect: true) selected",
            "^[%lld field](inflect: true) found",
            "Successfully cleaned and saved ^[%lld photo](inflect: true)."
        ]
        for locale in Self.locales {
            for key in keys {
                for count in [0, 1, 2, 5, 11, 100] {
                    let text = try format(key, locale: locale, count)
                    XCTAssertFalse(
                        text.contains("^[") || text.contains("inflect") || text.contains("%#@") || text.contains("%lld"),
                        "\(locale) n=\(count): “\(text)”"
                    )
                }
            }
        }
    }

    /// Polish needs three different noun forms (1 zdjęcie, 2 zdjęcia, 5 zdjęć);
    /// the grammar engine does not inflect Polish, so these must come from the catalog.
    func testPolishUsesOneFewAndManyForms() throws {
        let key = "^[%lld photo](inflect: true) selected"
        let forms = try [1, 2, 5].map { count in
            try format(key, locale: "pl", count).filter { !$0.isNumber }
        }
        XCTAssertEqual(Set(forms).count, 3, "Expected distinct one/few/many forms, got \(forms).")
    }

    /// A plural phrase embedded next to another argument binds to the right argument.
    func testPluralSubstitutionUsesTheCountArgument() throws {
        let key = "%@: redacting ^[%lld instance](inflect: true)"
        let one = try format(key, locale: "pl", "E-mail", 1)
        let many = try format(key, locale: "pl", "E-mail", 5)
        XCTAssertTrue(one.contains("E-mail") && one.contains("1"), one)
        XCTAssertTrue(many.contains("E-mail") && many.contains("5"), many)
        XCTAssertNotEqual(
            one.replacingOccurrences(of: "1", with: ""),
            many.replacingOccurrences(of: "5", with: ""),
            "Polish singular and genitive-plural forms should differ."
        )
    }

    /// The permission prompts and the share-sheet action name come from InfoPlist tables.
    func testInfoPlistStringsAreLocalized() throws {
        for locale in Self.locales {
            let value = try table(for: locale).localizedString(
                forKey: "NSPhotoLibraryAddUsageDescription", value: "missing", table: "InfoPlist"
            )
            XCTAssertNotEqual(value, "missing", "\(locale) has no localized photo-library prompt.")
            XCTAssertTrue(value.contains("PicStrip"), "\(locale): “\(value)”")
        }
    }
}
