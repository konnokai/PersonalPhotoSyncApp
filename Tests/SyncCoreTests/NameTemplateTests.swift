import XCTest
@testable import SyncCore

final class NameTemplateTests: XCTestCase {
    // 2026-10-13 14:05:09 UTC
    let date = Date(timeIntervalSince1970: 1_791_900_309)
    var ctx: NameContext {
        NameContext(originalName: "IMG_0001", assetID: "AB12-CD34/L0/001", creationDate: date,
                    albumName: "Trip/2026", deviceName: "iPhone", sequence: 1, outputExtension: "HEIC")
    }
    let utc = TimeZone(identifier: "UTC")!

    func render(_ t: String, ext: ExtensionCase = .keep) -> String {
        NameTemplate.render(t, context: ctx, timeZone: utc, extensionCase: ext)
    }

    func testFixedModes() {
        XCTAssertEqual(render(NameMode.original.template), "IMG_0001.HEIC")
        XCTAssertEqual(render(NameMode.timestamp.template), "2026-10-13_14-05-09.HEIC")
        XCTAssertEqual(render(NameMode.timestampOriginal.template), "2026-10-13_14-05-09_IMG_0001.HEIC")
    }

    func testDateTokens() {
        XCTAssertEqual(render("%yR%mR%dR-%HR%MR%SR"), "261013-140509")
    }

    func testIdUsesStablePartOfLocalIdentifier() {
        XCTAssertEqual(render("%ID"), "AB12-CD34")
        XCTAssertEqual(render("%ID"), render("%ID"))
    }

    func testTokenValuesAreSanitizedButTemplateSlashesStay() {
        XCTAssertEqual(render("%YR/%AP/%OP.%EP"), "2026/Trip_2026/IMG_0001.HEIC")
    }

    func testIllegalCharactersReplaced() {
        XCTAssertEqual(NameTemplate.sanitize("a:b*c?d\"e<f>g|h\\i"), "a_b_c_d_e_f_g_h_i")
    }

    func testExtensionCase() {
        XCTAssertEqual(render("%OP.%EP", ext: .lower), "IMG_0001.heic")
        XCTAssertEqual(render("%OP.%EP", ext: .upper), "IMG_0001.HEIC")
    }

    func testSequenceToken() {
        XCTAssertEqual(render("%OP_%IP"), "IMG_0001_1")
    }

    func testMissingDateUsesPlaceholder() {
        var c = ctx; c.creationDate = nil
        XCTAssertEqual(NameTemplate.render("%YR", context: c, timeZone: utc, extensionCase: .keep), "0000")
    }
}
