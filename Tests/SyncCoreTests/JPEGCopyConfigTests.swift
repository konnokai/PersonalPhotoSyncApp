import XCTest
@testable import SyncCore

final class JPEGCopyConfigTests: XCTestCase {
    func testDefaultsToOn() {
        XCTAssertTrue(SyncConfig().includeJPEGCopy)
    }

    /// 沒有這個 key 的舊設定檔要解得開、連線資料不掉，而且視為開啟。
    func testConfigSavedBeforeThisFieldExistedDecodesAsOn() throws {
        var old = SyncConfig()
        old.host = "nas.local"; old.share = "Own"
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        object.removeValue(forKey: "includeJPEGCopyStored")

        let decoded = try JSONDecoder().decode(SyncConfig.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.host, "nas.local")
        XCTAssertTrue(decoded.includeJPEGCopy)
    }

    func testOffRoundTrips() throws {
        var c = SyncConfig()
        c.includeJPEGCopy = false
        let decoded = try JSONDecoder().decode(SyncConfig.self, from: JSONEncoder().encode(c))
        XCTAssertFalse(decoded.includeJPEGCopy)
    }

    /// 沒動過設定（nil）和明確開啟（true）是同一種狀態，不能讓「已同步」集合作廢。
    func testUnsetAndExplicitOnShareFingerprint() {
        var explicit = SyncConfig()
        explicit.includeJPEGCopy = true
        XCTAssertEqual(SyncConfig().destinationFingerprint, explicit.destinationFingerprint)
    }
}
