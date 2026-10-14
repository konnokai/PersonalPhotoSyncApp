import XCTest
@testable import SyncCore

final class SubdirectoryPresetTests: XCTestCase {
    func testSampleIsRenderedFromTemplate() {
        let samples = Dictionary(uniqueKeysWithValues: SubdirectoryPreset.allCases.map { ($0, $0.sample) })
        XCTAssertEqual(samples[.none], "（直接放在根目錄）")
        XCTAssertEqual(samples[.yearMonth], "2026/03")
        XCTAssertEqual(samples[.yearThenYearMonth], "2026/2026-03")
        XCTAssertEqual(samples[.device], "iPhone")
        XCTAssertEqual(samples[.extensionName], "HEIC")
        XCTAssertEqual(samples[.deviceThenAlbum], "iPhone/QQ")
    }

    func testMatchingByTemplateString() {
        XCTAssertEqual(SubdirectoryPreset(template: ""), SubdirectoryPreset.none)
        XCTAssertEqual(SubdirectoryPreset(template: "%YR/%mR"), .yearMonth)
        XCTAssertNil(SubdirectoryPreset(template: "%YR/%OP"))
    }

    func testTemplatesAreUniqueAndUseOnlyStableTokens() {
        let templates = SubdirectoryPreset.allCases.map(\.template)
        XCTAssertEqual(Set(templates).count, templates.count)
        // 序號、識別碼、原檔名每張都不同，不適合當資料夾。
        for t in templates { for bad in ["%IP", "%ID", "%OP"] { XCTAssertFalse(t.contains(bad)) } }
    }
}
