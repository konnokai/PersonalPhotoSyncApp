import XCTest
@testable import SMBAdapter
import SyncCore

final class ConnectErrorTests: XCTestCase {
    func message(_ code: POSIXErrorCode, encrypted: Bool = false) -> String {
        AMSMBClient.connectErrorMessage(POSIXError(code), requireEncryption: encrypted)
    }

    func testCommonFailuresExplainTheLikelyCause() {
        XCTAssertTrue(message(.ECONNREFUSED).contains("帳號"))
        XCTAssertTrue(message(.ECONNREFUSED).contains("445"))
        XCTAssertTrue(message(.ETIMEDOUT).contains("逾時"))
        XCTAssertTrue(message(.EHOSTUNREACH).contains("區域網路"))
        XCTAssertTrue(message(.ENOENT).contains("共享名稱"))
        XCTAssertTrue(message(.EACCES).contains("權限"))
    }

    func testUnknownCodeKeepsTheCodeForDebugging() {
        XCTAssertTrue(message(.EPIPE).contains("\(POSIXErrorCode.EPIPE.rawValue)"))
    }

    func testEncryptionHintOnlyWhenRequired() {
        XCTAssertTrue(message(.EPIPE, encrypted: true).contains("加密"))
        XCTAssertFalse(message(.EPIPE).contains("加密"))
    }

    func testNonPOSIXErrorFallsBackToDescription() {
        let e = NSError(domain: "x", code: 9, userInfo: [NSLocalizedDescriptionKey: "boom"])
        XCTAssertTrue(AMSMBClient.connectErrorMessage(e, requireEncryption: false).contains("boom"))
    }

    func testConnectionLossIsMappedSoTheEngineCanStop() {
        for code in [POSIXErrorCode.ENOTCONN, .EPIPE, .ECONNRESET, .ETIMEDOUT, .ECONNABORTED] {
            guard case SMBError.disconnected = AMSMBClient.map(POSIXError(code)) else {
                return XCTFail("\(code) 應該對應成 disconnected")
            }
        }
        XCTAssertEqual(AMSMBClient.map(POSIXError(.ENOENT)) as? SMBError, .notFound)
        guard case SMBError.io = AMSMBClient.map(POSIXError(.EACCES)) else { return XCTFail("權限錯誤只是一般 io 錯誤") }
    }
}
