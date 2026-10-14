import XCTest
@testable import SyncCore

final class SyncStartDateTests: XCTestCase {
    private let cutoff = Date(timeIntervalSince1970: 1_769_731_200)   // 2026-01-30 00:00 UTC

    func testNoCutoffIncludesEverything() {
        XCTAssertTrue(SyncStartDate.includes(creationDate: Date(timeIntervalSince1970: 0), since: nil))
        XCTAssertTrue(SyncStartDate.includes(creationDate: nil, since: nil))
    }

    func testEarlierThanCutoffIsExcluded() {
        XCTAssertFalse(SyncStartDate.includes(creationDate: cutoff.addingTimeInterval(-1), since: cutoff))
    }

    func testCutoffInstantAndLaterAreIncluded() {
        XCTAssertTrue(SyncStartDate.includes(creationDate: cutoff, since: cutoff))
        XCTAssertTrue(SyncStartDate.includes(creationDate: cutoff.addingTimeInterval(1), since: cutoff))
    }

    /// 沒有拍攝時間的項目寧可上傳，也不要因為日期過濾而永遠被略過。
    func testMissingCreationDateIsIncluded() {
        XCTAssertTrue(SyncStartDate.includes(creationDate: nil, since: cutoff))
    }

    // MARK: - 設定檔

    /// AppModel 用預設的 JSONEncoder／JSONDecoder 存讀設定；解碼失敗會退回預設值，連線資料就掉了。
    func testConfigSavedBeforeThisFieldExistedStillDecodes() throws {
        var old = SyncConfig()
        old.host = "nas.local"; old.share = "Own"; old.username = "jun"
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        object.removeValue(forKey: "syncFromDate")
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SyncConfig.self, from: data)
        XCTAssertEqual(decoded.host, "nas.local")
        XCTAssertEqual(decoded.share, "Own")
        XCTAssertNil(decoded.syncFromDate)
    }

    func testConfigRoundTripsCutoff() throws {
        var c = SyncConfig()
        c.syncFromDate = cutoff
        let decoded = try JSONDecoder().decode(SyncConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded.syncFromDate, cutoff)
    }

    /// 日期只決定哪些項目參與，不影響檔案放哪、叫什麼，所以改日期不該讓「已同步」集合作廢。
    func testCutoffIsNotPartOfFingerprint() {
        var a = SyncConfig(); a.host = "nas"
        var b = a; b.syncFromDate = cutoff
        XCTAssertEqual(a.destinationFingerprint, b.destinationFingerprint)
    }
}
