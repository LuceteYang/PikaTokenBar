import Foundation
import XCTest
@testable import PokeTokenBar

/// Every README names every UI language the app ships.
///
/// Russian reached the Korean and Japanese READMEs in 1.10.0 but not the English one, and the
/// upstream merge that fixed upstream's copy kept this fork's sentence on conflict, so the gap
/// survived two releases. A language list in prose has nothing that notices a new `AppLanguage`
/// case — this does.
final class ReadmeLanguageListTests: XCTestCase {
    private func readme(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// The bold language list in the settings paragraph, e.g. `<b>KO / EN / … </b>`.
    private func languageList(in text: String, containing marker: String) throws -> String {
        let bolds = text.components(separatedBy: "<b>").dropFirst().compactMap { $0.components(separatedBy: "</b>").first }
        return try XCTUnwrap(bolds.first { $0.contains(marker) }, "no <b>…</b> language list containing \(marker)")
    }

    func testEnglishReadmeListsEveryLanguageCode() throws {
        let list = try languageList(in: readme("README.md"), containing: "KO /")
        let codes = Set(list.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) })
        XCTAssertEqual(codes, Set(AppLanguage.allCases.map { $0.rawValue.uppercased() }))
    }

    /// Names come from Foundation's own language names, so the test holds no translation table
    /// that could drift on its own.
    func testKoreanAndJapaneseReadmesNameEveryLanguage() throws {
        for (file, locale, separator) in [("README.ko.md", "ko", "/"), ("README.ja.md", "ja", "／")] {
            let names = Locale(identifier: locale)
            let first = try XCTUnwrap(names.localizedString(forLanguageCode: "ko"))
            let list = try languageList(in: readme(file), containing: first)
            let listed = Set(list.components(separatedBy: separator))
            for language in AppLanguage.allCases {
                let name = try XCTUnwrap(names.localizedString(forLanguageCode: language.rawValue))
                XCTAssertTrue(listed.contains(name), "\(file) is missing \(name)")
            }
            XCTAssertEqual(listed.count, AppLanguage.allCases.count, "\(file) lists a language the app does not ship")
        }
    }
}
